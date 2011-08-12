module RankedModel

  class InvalidScope < StandardError; end
  class InvalidField < StandardError; end

  class Ranker
    attr_accessor :name, :column, :scope, :with_same

    def initialize name, options={}
      @name = name.to_sym
      @column = options[:column] || name
      @scope, @with_same = options.values_at :scope, :with_same
    end

    # instance is the AR object
    def with instance
      Mapper.new self, instance
    end

    def to_options
      {:name => @name, :column => @column, :scope => @scope, :with_same => @with_same}
    end

    class ModelProxy < BasicObject
      extend ::Forwardable

      attr_reader :name, :column, :scope, :with_same

      def initialize(instance, options)
        @instance = instance
        @name, @column, @scope, @with_same = options.values_at :name, :column, :scope, :with_same

        validate_options!
      end

      def_delegators :@instance, :respond_to?, :class, :raise, :new_record?, :id, :[]

      def update_rank! value
        # Bypass callbacks
        #
        @instance.class.where(:id => id).update_all @column => value
      end

      def position
        @instance.send "#{@name}_position"
      end

      def rank
        @instance.send "#{@column}"
      end

      def rank_at value
        @instance.send "#{@column}=", value
      end

      def rank_changed?
        @instance.send "#{@column}_changed?"
      end

      def position=(value)
        @instance.send "#{@name}_position=", value
      end

      def validate_options!
        if @scope && !@instance.class.respond_to?(@scope)
          ::Kernel.raise ::RankedModel::InvalidScope, %Q{No scope called "#{@scope}" found in model}
        end

        has_valid_with_same = case @with_same
          when ::Symbol
            respond_to?(@with_same)
          when ::Array
            @with_same.any? {|attr| respond_to?(attr) }
          else
            true
        end

        unless has_valid_with_same
          ::Kernel.raise ::RankedModel::InvalidField, %Q{No field called "#{@with_same}" found in model}
        end
      end

      def arel_table
        @instance.class.arel_table
      end

      def arel_column
        arel_table[@column]
      end

      def eq(attr)
        arel_table[attr].eq(self[attr])
      end

      def base_relation
        _finder = @instance.class
        _finder = _finder.send @scope if @scope
        _finder = _finder.where arel_table[:id].not_eq(id) unless new_record?
        _finder = _finder.where with_same_eq_stmt if @with_same

        _finder
      end

      def with_same_eq_stmt
        case @with_same
          when ::Symbol
            eq(@with_same)
          when ::Array
            @with_same[1..-1].inject( eq(@with_same.first) ) do |scoper, attr|
              scoper.and eq(attr)
            end
        end
      end
    end

    class Mapper
      attr_accessor :ranker, :instance

      def initialize ranker, instance
        @ranker   = ranker
        @instance = instance
        @model = ModelProxy.new(instance, ranker.to_options)
      end

      def handle_ranking
        update_index_from_position
        assure_unique_position
      end

      extend ::Forwardable
      def_delegators :@model, :update_rank!, :rank

      def current_at_position _pos
        if (ordered_instance = finder.offset(_pos).first)
          RankedModel::Ranker::Mapper.new @ranker, ordered_instance
        end
      end

    private

      def position_at value
        @model.position = value
        update_index_from_position
      end

      def update_index_from_position
        case @model.position
          when :first
            if current_first && current_first.rank
              @model.rank_at( ( ( RankedModel::MIN_RANK_VALUE - current_first.rank ).to_f / 2 ).ceil + current_first.rank)
            else
              position_at :middle
            end
          when :last
            if current_last && current_last.rank
              @model.rank_at( ( ( RankedModel::MAX_RANK_VALUE - current_last.rank ).to_f / 2 ).ceil + current_last.rank )
            else
              position_at :middle
            end
          when :middle
            @model.rank_at( RankedModel::MEDIAN_RANK_VALUE )
          when String
            position_at position.to_i
          when 0
            position_at :first
          when Integer
            neighbors = neighbors_at_position(@model.position)
            min = (neighbors[:lower] ? neighbors[:lower].rank : RankedModel::MIN_RANK_VALUE)
            max = (neighbors[:upper] ? neighbors[:upper].rank : RankedModel::MAX_RANK_VALUE)
            @model.rank_at( ( ( max - min ).to_f / 2 ).ceil + min )
          when NilClass
            if !@model.rank
              position_at :last
            end
        end
      end

      def assure_unique_position
        if ( @model.new_record? || @model.rank_changed? )
          unless @model.rank
            @model.rank_at( RankedModel::MAX_RANK_VALUE )
          end

          if (@model.rank > RankedModel::MAX_RANK_VALUE) || current_at_rank(rank)
            rearrange_ranks
          end
        end
      end

      # finder
      def rearrange_ranks
        if current_first.rank > RankedModel::MIN_RANK_VALUE && @model.rank == RankedModel::MAX_RANK_VALUE
          @model.base_relation.
            where( @model.arel_column.lteq(rank) ).
            update_all( "#{@model.column} = #{@model.column} - 1" )
        elsif current_last.rank < (RankedModel::MAX_RANK_VALUE - 1) && @model.rank < current_last.rank
          @model.base_relation.
            where( @model.arel_column.gteq(rank) ).
            update_all( "#{@model.column} = #{@model.column} + 1" )
        elsif current_first.rank > RankedModel::MIN_RANK_VALUE && @model.rank > current_first.rank
          @model.base_relation.
            where( @model.arel_column.lt(rank) ).
            update_all( "#{@model.column} = #{@model.column} - 1" )
          @model.rank_at( @model.rank - 1 )
        else
          rebalance_ranks
        end
      end

      def rebalance_ranks
        total = current_order.size + 2
        has_set_self = false
        total.times do |index|
          next if index == 0 || index == total
          rank_value = ((((RankedModel::MAX_RANK_VALUE - RankedModel::MIN_RANK_VALUE).to_f / total) * index ).ceil + RankedModel::MIN_RANK_VALUE)
          index = index - 1
          if has_set_self
            index = index - 1
          else
            if !current_order[index] ||
               ( !current_order[index].rank.nil? &&
                 current_order[index].rank >= @model.rank)
              @model.rank_at rank_value
              has_set_self = true
              next
            end
          end
          current_order[index].update_rank! rank_value
        end
      end

      # finder
      def finder
        @finder ||= begin
          _finder = @model.base_relation
          _finder.order(@model.arel_column.asc).select([:id, @model.column])
        end
      end

      def current_order
        @current_order ||= begin
          finder.collect { |ordered_instance|
            RankedModel::Ranker::Mapper.new @ranker, ordered_instance
          }
        end
      end

      def current_first
        @current_first ||= begin
          if (ordered_instance = finder.first)
            RankedModel::Ranker::Mapper.new @ranker, ordered_instance
          end
        end
      end

      def current_last
        @current_last ||= begin
          if (ordered_instance = finder.
                                   except( :order ).
                                   order( @model.arel_column.desc ).
                                   first)
            RankedModel::Ranker::Mapper.new @ranker, ordered_instance
          end
        end
      end

      def current_at_rank _rank
        if (ordered_instance = finder.
                                 except( :order ).
                                 where( @model.column => _rank ).
                                 first)
          RankedModel::Ranker::Mapper.new @ranker, ordered_instance
        end
      end

      def neighbors_at_position _pos
        if _pos > 0
          if (ordered_instances = finder.offset(_pos-1).limit(2).all)
            if ordered_instances[1]
              { :lower => RankedModel::Ranker::Mapper.new( @ranker, ordered_instances[0] ),
                :upper => RankedModel::Ranker::Mapper.new( @ranker, ordered_instances[1] ) }
            elsif ordered_instances[0]
              { :lower => RankedModel::Ranker::Mapper.new( @ranker, ordered_instances[0] ) }
            else
              { :lower => current_last }
            end
          end
        else
          if (ordered_instance = finder.first)
            { :upper => RankedModel::Ranker::Mapper.new( @ranker, ordered_instance ) }
          else
            {}
          end
        end
      end

    end

  end

end
