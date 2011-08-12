require 'spec_helper'

describe Duck, "with same pond" do
  before do
    25.times do |i|
      Duck.create :name => "Shin #{i}", :pond => "Shin"
    end
  end

  it "creating ducks in Boyden should not affect the ducks age rank in Shin" do
    shin_ducks = Duck.where(:pond => "Shin").all

    25.times do |i|
      boyden_duck = Duck.create :name => "Boyden #{i}", :pond => "Boyden"

      shin_ducks.each do |duck|
        age = duck.age

        (duck.reload.age == age).should be_true, "#{boyden_duck.name} changed the age for #{duck.name}"
      end
    end
  end
end
