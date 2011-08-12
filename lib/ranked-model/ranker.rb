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

      def initialize(instance, options)
        @instance = instance
        @name, @column, @scope, @with_same = options.values_at :name, :column, :scope, :with_same

        validate_options!
      end

      def_delegators :@instance, :respond_to?, :class, :raise, :new_record?

      def update_rank! value
        # Bypass callbacks
        #
        @instance.class.where(:id => @instance.id).update_all @column => value
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
      def_delegators :@model, :update_rank!, :rank, :position, :rank_at, :rank_changed?, :new_record?

      def current_at_position _pos
        if (ordered_instance = finder.offset(_pos).first)
          RankedModel::Ranker::Mapper.new @ranker, ordered_instance
        end
      end

    private

      def position_at value
        @instance.send "#{@ranker.name}_position=", value
        update_index_from_position
      end

      def update_index_from_position
        case position
          when :first
            if current_first && current_first.rank
              rank_at( ( ( RankedModel::MIN_RANK_VALUE - current_first.rank ).to_f / 2 ).ceil + current_first.rank)
            else
              position_at :middle
            end
          when :last
            if current_last && current_last.rank
              rank_at( ( ( RankedModel::MAX_RANK_VALUE - current_last.rank ).to_f / 2 ).ceil + current_last.rank )
            else
              position_at :middle
            end
          when :middle
            rank_at( ( ( RankedModel::MAX_RANK_VALUE - RankedModel::MIN_RANK_VALUE ).to_f / 2 ).ceil + RankedModel::MIN_RANK_VALUE )
          when String
            position_at position.to_i
          when 0
            position_at :first
          when Integer
            neighbors = neighbors_at_position(position)
            min = (neighbors[:lower] ? neighbors[:lower].rank : RankedModel::MIN_RANK_VALUE)
            max = (neighbors[:upper] ? neighbors[:upper].rank : RankedModel::MAX_RANK_VALUE)
            rank_at( ( ( max - min ).to_f / 2 ).ceil + min )
          when NilClass
            if !rank
              position_at :last
            end
        end
      end

      def assure_unique_position
        if ( new_record? || rank_changed? )
          unless rank
            rank_at( RankedModel::MAX_RANK_VALUE )
          end

          if (rank > RankedModel::MAX_RANK_VALUE) || current_at_rank(rank)
            rearrange_ranks
          end
        end
      end

      def rearrange_ranks
        if current_first.rank > RankedModel::MIN_RANK_VALUE && rank == RankedModel::MAX_RANK_VALUE
          @instance.class.
            where( @instance.class.arel_table[:id].not_eq(@instance.id) ).
            where( @instance.class.arel_table[@ranker.column].lteq(rank) ).
            update_all( "#{@ranker.column} = #{@ranker.column} - 1" )
        elsif current_last.rank < (RankedModel::MAX_RANK_VALUE - 1) && rank < current_last.rank
          @instance.class.
            where( @instance.class.arel_table[:id].not_eq(@instance.id) ).
            where( @instance.class.arel_table[@ranker.column].gteq(rank) ).
            update_all( "#{@ranker.column} = #{@ranker.column} + 1" )
        elsif current_first.rank > RankedModel::MIN_RANK_VALUE && rank > current_first.rank
          @instance.class.
            where( @instance.class.arel_table[:id].not_eq(@instance.id) ).
            where( @instance.class.arel_table[@ranker.column].lt(rank) ).
            update_all( "#{@ranker.column} = #{@ranker.column} - 1" )
          rank_at( rank - 1 )
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
                 current_order[index].rank >= rank )
              rank_at rank_value
              has_set_self = true
              next
            end
          end
          current_order[index].update_rank! rank_value
        end
      end

      def finder
        @finder ||= begin
          _finder = @instance.class
          if @ranker.scope
            _finder = _finder.send @ranker.scope
          end
          case @ranker.with_same
            when Symbol
              _finder = _finder.where \
                @instance.class.arel_table[@ranker.with_same].eq(@instance.attributes["#{@ranker.with_same}"])
            when Array
              _finder = _finder.where(
                @ranker.with_same[1..-1].inject(
                  @instance.class.arel_table[@ranker.with_same.first].eq(
                    @instance.attributes["#{@ranker.with_same.first}"]
                  )
                ) {|scoper, attr|
                  scoper.and(
                    @instance.class.arel_table[attr].eq(
                      @instance.attributes["#{attr}"]
                    )
                  )
                }
              )
          end
          if !new_record?
            _finder = _finder.where \
              @instance.class.arel_table[:id].not_eq(@instance.id)
          end
          _finder.order(@instance.class.arel_table[@ranker.column].asc).select([:id, @ranker.column])
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
                                   order( @instance.class.arel_table[@ranker.column].desc ).
                                   first)
            RankedModel::Ranker::Mapper.new @ranker, ordered_instance
          end
        end
      end

      def current_at_rank _rank
        if (ordered_instance = finder.
                                 except( :order ).
                                 where( @ranker.column => _rank ).
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
