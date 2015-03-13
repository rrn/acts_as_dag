require 'spec_helper'

describe 'acts_as_dag' do
  shared_examples_for "DAG Model" do
    before(:each) do
      @klass.destroy_all # Because we're using sqlite3 and it doesn't support transactional specs (afaik)
    end

    let (:grandpa) { @klass.create(:name => 'grandpa') }
    let (:dad) { @klass.create(:name => 'dad') }
    let (:mom) { @klass.create(:name => 'mom') }
    let (:suzy) { @klass.create(:name => 'suzy') }
    let (:billy) { @klass.create(:name => 'billy') }

    describe '#children' do
      it "returns an ActiveRecord::Relation" do
        expect(mom.children).to be_an(ActiveRecord::Relation)
      end

      it "includes all children of the receiver" do
        mom.add_child(suzy, billy)
        expect(mom.children).to include(suzy,billy)
      end

      it "doesn't include any records that are not children of the receiver" do
        grandpa.add_child(mom)
        expect(mom.children).not_to include(grandpa)
      end

      it "returns records in the order they were added to the graph" do
        grandpa.add_child(mom, dad)
        expect(grandpa.children).to eq([mom, dad])
      end
    end

    describe '#parents' do
      it "returns an ActiveRecord::Relation" do
        expect(mom.parents).to be_an(ActiveRecord::Relation)
      end

      it "includes all parents of the receiver" do
        suzy.add_parent(mom, dad)
        expect(suzy.parents).to include(mom, dad)
      end

      it "doesn't include any records that are not parents of the receiver" do
        dad.add_parent(grandpa)
        suzy.add_parent(mom, dad)
        expect(suzy.parents).not_to include(grandpa)
      end

      it "returns records in the order they were added to the graph" do
        suzy.add_parent(mom, dad)
        expect(suzy.parents).to eq([mom, dad])
      end
    end

    describe '#descendants' do
      it "returns an ActiveRecord::Relation" do
        expect(mom.descendants).to be_an(ActiveRecord::Relation)
      end

      it "doesn't include self" do
        expect(mom.descendants).not_to include(mom)
      end

      it "includes all descendants of the receiver" do
        grandpa.add_child(mom, dad)
        mom.add_child(suzy)
        dad.add_child(billy)
        expect(grandpa.descendants).to include(mom, dad, suzy, billy)
      end

      it "doesn't include any ancestors of the receiver" do
        grandpa.add_child(mom)
        mom.add_child(suzy)
        expect(mom.descendants).not_to include(grandpa)
      end

      it "returns records in ascending order of distance, and ascending order added to graph" do
        grandpa.add_child(mom, dad)
        mom.add_child(suzy)
        dad.add_child(billy)
        expect(grandpa.descendants).to eq([mom, dad, suzy, billy])
      end
    end

    describe '#subtree' do
      it "returns an ActiveRecord::Relation" do
        expect(mom.subtree).to be_an(ActiveRecord::Relation)
      end

      it "includes self" do
        expect(mom.subtree).to include(mom)
      end

      it "includes all descendants of the receiver" do
        grandpa.add_child(mom)
        mom.add_child(billy)
        expect(grandpa.subtree).to include(mom, billy)
      end

      it "doesn't include any ancestors of the receiver" do
        grandpa.add_child(mom)
        mom.add_child(billy)
        expect(mom.subtree).not_to include(grandpa)
      end

      it "returns records in ascending order of distance, and ascending order added to graph" do
        grandpa.add_child(mom)
        grandpa.add_child(dad)
        mom.add_child(billy)
        expect(grandpa.subtree).to eq([grandpa, mom, dad, billy])
      end
    end

    describe '#ancestors' do
      it "returns an ActiveRecord::Relation" do
        expect(mom.ancestors).to be_an(ActiveRecord::Relation)
      end

      it "doesn't include self" do
        expect(mom.ancestors).not_to include(mom)
      end

      it "includes all ancestors of the receiver" do
        grandpa.add_child(mom)
        mom.add_child(billy)
        expect(billy.ancestors).to include(grandpa, mom)
      end

      it "doesn't include any descendants of the receiver" do
        grandpa.add_child(mom)
        mom.add_child(billy)
        expect(mom.ancestors).not_to include(billy)
      end

      it "returns records in descending order of distance, and ascending order added to graph" do
        grandpa.add_child(mom)
        grandpa.add_child(dad)
        mom.add_child(billy)
        expect(billy.ancestors).to eq([grandpa, mom, dad, billy])
      end
    end

    describe '#path' do
      it "returns an ActiveRecord::Relation" do
        expect(mom.path).to be_an(ActiveRecord::Relation)
      end

      it "includes self" do
        expect(mom.path).to include(mom)
      end

      it "includes all ancestors of the receiver" do
        grandpa.add_child(mom)
        mom.add_child(billy)
        dad.add_child(billy)
        expect(billy.path).to include(grandpa, mom, dad)
      end

      it "doesn't include any descendants of the receiver" do
        grandpa.add_child(mom)
        mom.add_child(billy)
        expect(mom.path).not_to include(billy)
      end

      it "returns records in descending order of distance, and ascending order added to graph" do
        grandpa.add_child(mom)
        mom.add_child(billy)
        dad.add_child(billy)
        expect(billy.path).to eq([grandpa, mom, dad, billy])
      end
    end

    describe '#add_child' do
      it "makes the record a child of the receiver" do
        mom.add_child(billy)
        expect(billy.child_of?(mom)).to be_truthy
      end

      it "makes the record a descendant of the receiver" do
        mom.add_child(billy)
        expect(billy.descendant_of?(mom)).to be_truthy
      end

      it "makes the record an descendant of any of the receiver's ancestors" do
        grandpa.add_child(mom)
        mom.add_child(billy)
        expect(billy.descendant_of?(grandpa)).to be_truthy
      end

      it "can be called multiple times to add additional children" do
        mom.add_child(suzy)
        mom.add_child(billy)
        expect(mom.children).to include(suzy, billy)
      end

      it "accepts multiple arguments, adding each as a child" do
        mom.add_child(suzy, billy)
        expect(mom.children).to include(suzy, billy)
      end

      it "accepts an array of records, adding each as a child" do
        mom.add_child([suzy, billy])
        expect(mom.children).to include(suzy, billy)
      end
    end

    describe '#add_parent' do
      it "makes the record a parent of the receiver" do
        suzy.add_parent(dad)
        expect(dad.parent_of?(suzy)).to be_truthy
      end

      it "makes the record a ancestor of the receiver" do
        suzy.add_parent(dad)
        expect(dad.ancestor_of?(suzy)).to be_truthy
      end

      it "makes the record an ancestor of any of the receiver's ancestors" do
        dad.add_parent(grandpa)
        suzy.add_parent(dad)
        expect(grandpa.ancestor_of?(suzy)).to be_truthy
      end

      it "can be called multiple times to add additional parents" do
        suzy.add_parent(mom)
        suzy.add_parent(dad)
        expect(suzy.parents).to include(mom, dad)
      end

      it "accepts multiple arguments, adding each as a parent" do
        suzy.add_parent(mom, dad)
        expect(suzy.parents).to include(mom, dad)
      end

      it "accepts an array of records, adding each as a parent" do
        suzy.add_parent([mom, dad])
        expect(suzy.parents).to include(mom, dad)
      end
    end

    describe '#ancestor_of?' do
      it "returns true if the record is a ancestor of the receiver" do
        grandpa.add_child(mom)
        mom.add_child(billy)
        expect(grandpa.ancestor_of?(billy)).to be_truthy
      end

      it "returns false if the record is not an ancestor of the receiver" do
        grandpa.add_child(dad)
        mom.add_child(billy)
        expect(grandpa.ancestor_of?(billy)).to be_falsey
      end
    end

    describe '#descendant_of?' do
      it "returns true if the record is a descendant of the receiver" do
        grandpa.add_child(mom)
        mom.add_child(billy)
        expect(billy.descendant_of?(grandpa)).to be_truthy
      end

      it "returns false if the record is not an descendant of the receiver" do
        grandpa.add_child(dad)
        mom.add_child(billy)
        expect(billy.descendant_of?(grandpa)).to be_falsey
      end
    end

    describe '#child_of?' do
      it "returns true if the record is a child of the receiver" do
        mom.add_child(billy)
        expect(billy.child_of?(mom)).to be_truthy
      end

      it "returns false if the record is not an child of the receiver" do
        mom.add_child(suzy)
        expect(billy.child_of?(mom)).to be_falsey
      end
    end

    describe '#parent_of?' do
      it "returns true if the record is a parent of the receiver" do
        mom.add_child(billy)
        expect(mom.parent_of?(billy)).to be_truthy
      end

      it "returns false if the record is not an parent of the receiver" do
        mom.add_child(billy)
        expect(mom.parent_of?(suzy)).to be_falsey
      end
    end

    describe '#root?' do
      it "returns true if the record has no parents" do
        mom.add_child(suzy)
        expect(mom.root?).to be_truthy
      end

      it "returns false if the record has parents" do
        mom.add_parent(grandpa)
        expect(mom.root?).to be_falsey
      end
    end

    describe '#leaf?' do
      it "returns true if the record has no children" do
        mom.add_parent(grandpa)
        expect(mom.leaf?).to be_truthy
      end

      it "returns false if the record has children" do
        mom.add_child(suzy)
        expect(mom.leaf?).to be_falsey
      end
    end

    describe '#make_root' do
      it "makes the receiver a root node" do
        mom.add_parent(grandpa)
        mom.make_root
        expect(mom.root?).to be_truthy
      end

      it "removes the receiver from the children of its parents" do
        suzy.add_parent(mom, dad)
        suzy.make_root
        expect(mom.children).not_to include(suzy)
        expect(dad.children).not_to include(suzy)
      end

      it "doesn't modify the relationship between the receiver and its descendants" do
        mom.add_parent(grandpa)
        mom.add_child(suzy, billy)
        mom.make_root
        expect(mom.children).to eq([suzy, billy])
      end
    end

    describe '#lineage' do
      it "returns an ActiveRecord::Relation" do
        expect(mom.children).to be_an(ActiveRecord::Relation)
      end

      it "doesn't include the receiver" do
        expect(mom.lineage).not_to include(mom)
      end

      it "return ancestors and descendants of the receiver in the order they would be if called separately" do
        mom.add_parent(grandpa)
        mom.add_child(suzy, billy)
        expect(mom.lineage).to eq([grandpa, suzy, billy])
      end
    end

    describe '::children' do
      it "returns an ActiveRecord::Relation" do
        expect(@klass.children).to be_an(ActiveRecord::Relation)
      end

      it "returns records that have at least 1 parent" do
        mom.add_parent(grandpa)
        mom.add_child(suzy)
        expect(@klass.children).to include(mom, suzy)
      end

      it "doesn't returns records without parents" do
        mom.add_parent(grandpa)
        mom.add_child(suzy)
        expect(@klass.children).not_to include(grandpa)
      end

      it "does not return duplicate records, regardless of the number of parents" do
        suzy.add_parent(mom, dad)
        expect(@klass.children).to eq([suzy])
      end
    end

    describe '::parents' do
      it "returns an ActiveRecord::Relation" do
        expect(@klass.parents).to be_an(ActiveRecord::Relation)
      end

      it "returns records that have at least 1 child" do
        mom.add_parent(grandpa)
        mom.add_child(suzy)
        expect(@klass.parents).to include(grandpa, mom)
      end

      it "doesn't returns records without children" do
        mom.add_parent(grandpa)
        mom.add_child(suzy)
        expect(@klass.parents).not_to include(suzy)
      end

      it "does not return duplicate records, regardless of the number of children" do
        mom.add_child(suzy, billy)
        expect(@klass.parents).to eq([mom])
      end
    end

    # context "when a record hierarchy exists" do
    #   before do
    #     grandma.add_child(mom)
    #     mom.add_child(suzy)
    #   end

    #   it "destroys associated hierarchy-tracking records when a record is destroyed" do
    #     mom.destroy
    #     mom.descendant_links.should be_empty
    #     mom.ancestor_links.should be_empty
    #     mom.parent_links.should be_empty
    #     mom.child_links.should be_empty
    #   end
    # end




    # describe "reorganization" do
    #   before(:each) do
    #     @totem = @klass.create(:name => "totem")
    #     @totem_pole = @klass.create(:name => "totem pole")
    #     @big_totem_pole = @klass.create(:name => "big totem pole")
    #     @big_model_totem_pole = @klass.create(:name => "big model totem pole")
    #     @big_red_model_totem_pole = @klass.create(:name => "big red model totem pole")
    #   end

    #   it "should reinitialize links and descendants after resetting the hierarchy" do
    #     @klass.reset_hierarchy
    #     @big_totem_pole.parents.should == []
    #     @big_totem_pole.children.should == []
    #     @big_totem_pole.ancestors.should == [@big_totem_pole]
    #     @big_totem_pole.descendants.should == [@big_totem_pole]
    #   end

    #   it "should be able to determine whether one category is an ancestor of the other by inspecting the name" do
    #     ActsAsDAG::Deprecated::HelperMethods.should_descend_from?(@totem_pole, @big_totem_pole).should be_truthy
    #     ActsAsDAG::Deprecated::HelperMethods.should_descend_from?(@big_totem_pole, @totem_pole).should be_falsy
    #   end

    #   it "should be able to determine the number of matching words in two categories names" do
    #     ActsAsDAG::Deprecated::HelperMethods.matching_word_count(@totem_pole, @big_totem_pole).should == 2
    #   end

    #   it "should arrange the categories correctly when not passed any arguments" do
    #     @klass.reorganize

    #     @totem.children.should == [@totem_pole]
    #     @totem_pole.children.should == [@big_totem_pole]
    #     @big_totem_pole.children.should == [@big_model_totem_pole]
    #     @big_model_totem_pole.children.should == [@big_red_model_totem_pole]
    #   end

    #   it "should arrange the categories correctly when passed a set of nodes to reorganize" do
    #     @klass.reorganize [@totem, @totem_pole, @big_totem_pole, @big_model_totem_pole, @big_red_model_totem_pole]

    #     @totem.reload.children.should == [@totem_pole]
    #     @totem_pole.reload.children.should == [@big_totem_pole]
    #     @big_totem_pole.reload.children.should == [@big_model_totem_pole]
    #     @big_model_totem_pole.reload.children.should == [@big_red_model_totem_pole]
    #   end

    #   it "should arrange the categories correctly when inserting a category into an existing chain" do
    #     @totem.add_child(@big_totem_pole)

    #     @klass.reorganize

    #     @totem.children.should == [@totem_pole]
    #     @totem_pole.children.should == [@big_totem_pole]
    #     @big_totem_pole.children.should == [@big_model_totem_pole]
    #     @big_model_totem_pole.reload.children.should == [@big_red_model_totem_pole]
    #   end

    #   it "should still work when there are categories that are permutations of each other" do
    #     @big_totem_pole_model = @klass.create(:name => "big totem pole model")

    #     @klass.reorganize [@totem, @totem_pole, @big_totem_pole, @big_model_totem_pole, @big_red_model_totem_pole, @big_totem_pole_model]

    #     @totem.children.should == [@totem_pole]
    #     @totem_pole.children.should == [@big_totem_pole]
    #     (@big_totem_pole.children - [@big_model_totem_pole, @big_totem_pole_model]).should == []
    #     @big_model_totem_pole.reload.children.should == [@big_red_model_totem_pole]
    #     @big_totem_pole_model.reload.children.should == [@big_red_model_totem_pole]
    #   end

    #   describe "when there is a single long inheritance chain" do
    #     before(:each) do
    #       @totem.add_child(@totem_pole)
    #       @totem_pole.add_child(@big_totem_pole)
    #       @big_totem_pole.add_child(@big_model_totem_pole)
    #       @big_model_totem_pole.add_child(@big_red_model_totem_pole)
    #     end

    #     describe "and we are reorganizing the middle of the chain" do
    #       # Totem
    #       #   |
    #       # Totem Pole
    #       #  *|*       \
    #       #  *|*      Big Totem Pole
    #       #  *|*       /
    #       # Big Model Totem Pole
    #       #   |
    #       # Big Red Model Totem Pole
    #       #
    #       before(:each) do
    #         @totem_pole.add_child(@big_model_totem_pole)
    #       end

    #       it "should return multiple instances of descendants before breaking the old link" do
    #         @totem.descendants.sort_by(&:id).should == [@totem, @totem_pole, @big_totem_pole, @big_model_totem_pole, @big_model_totem_pole, @big_red_model_totem_pole, @big_red_model_totem_pole].sort_by(&:id)
    #       end

    #       it "should return the correct inheritance chain after breaking the old link" do
    #         @totem_pole.remove_child(@big_model_totem_pole)

    #         @totem_pole.children.sort_by(&:id).should == [@big_totem_pole].sort_by(&:id)
    #         @totem.descendants.sort_by(&:id).should == [@totem, @totem_pole, @big_totem_pole, @big_model_totem_pole, @big_red_model_totem_pole].sort_by(&:id)
    #       end

    #       it "should return the correct inheritance chain after breaking the old link when there is are two ancestor root nodes" do
    #         pole = @klass.create(:name => "pole")
    #         @totem_pole.add_parent(pole)
    #         @totem_pole.remove_child(@big_model_totem_pole)

    #         pole.descendants.sort_by(&:id).should == [pole, @totem_pole, @big_totem_pole, @big_model_totem_pole, @big_red_model_totem_pole].sort_by(&:id)
    #         @totem_pole.children.sort_by(&:id).should == [@big_totem_pole].sort_by(&:id)
    #         @totem.descendants.sort_by(&:id).should == [@totem, @totem_pole, @big_totem_pole, @big_model_totem_pole, @big_red_model_totem_pole].sort_by(&:id)
    #       end
    #     end
    #   end
    # end

    # describe "and two paths of the same length exist to the same node" do
    #   before(:each) do
    #     @grandpa = @klass.create(:name => 'grandpa')
    #     @dad = @klass.create(:name => 'dad')
    #     @mom = @klass.create(:name => 'mom')
    #     @child = @klass.create(:name => 'child')

    #     # nevermind the incest
    #     @grandpa.add_child(@dad)
    #     @dad.add_child(@child)
    #     @child.add_parent(@mom)
    #     @mom.add_parent(@grandpa)
    #   end

    #   it "descendants should not return multiple instances of a child" do
    #     @grandpa.descendants.sort_by(&:id).should == [@grandpa, @dad, @mom, @child].sort_by(&:id)
    #   end

    #   describe "and a link between parent and ancestor is removed" do
    #     before(:each) do
    #       # the incest is undone!
    #       @dad.remove_parent(@grandpa)
    #     end

    #     it "should still return the correct ancestors" do
    #       @child.ancestors.sort_by(&:id).should == [@grandpa, @dad, @mom, @child].sort_by(&:id)
    #       @mom.ancestors.sort_by(&:id).should == [@grandpa, @mom].sort_by(&:id)
    #       @dad.ancestors.sort_by(&:id).should == [@dad].sort_by(&:id)
    #     end

    #     it "should still return the correct descendants" do
    #       @child.descendants.sort_by(&:id).should == [@child].sort_by(&:id)
    #       @mom.descendants.sort_by(&:id).should == [@mom, @child].sort_by(&:id)
    #       @dad.descendants.sort_by(&:id).should == [@dad, @child].sort_by(&:id)
    #       @grandpa.descendants.sort_by(&:id).should == [@grandpa, @mom, @child].sort_by(&:id)
    #     end
    #   end
    # end

    # describe "Includes, Eager-Loads, and Preloads" do
    #   before(:each) do
    #     @grandpa = @klass.create(:name => 'grandpa')
    #     @dad = @klass.create(:name => 'dad')
    #     @mom = @klass.create(:name => 'mom')
    #     @child = @klass.create(:name => 'child')

    #     @dad.add_parent(@grandpa)
    #     @child.add_parent(@dad)
    #     @child.add_parent(@mom)
    #   end

    #   it "should preload ancestors in the correct order" do
    #     records = @klass.order("#{@klass.table_name}.id asc").preload(:ancestors)

    #     records[0].ancestors.should == [@grandpa]                      # @grandpa
    #     records[1].ancestors.should == [@grandpa, @dad]                # @dad
    #     records[2].ancestors.should == [@mom]                          # @mom
    #     records[3].ancestors.should == [@grandpa, @dad, @mom, @child]  # @child
    #   end

    #   it "should eager_load ancestors in the correct order" do
    #     records = @klass.order("#{@klass.table_name}.id asc").eager_load(:ancestors)

    #     records[0].ancestors.should == [@grandpa]                      # @grandpa
    #     records[1].ancestors.should == [@grandpa, @dad]                # @dad
    #     records[2].ancestors.should == [@mom]                          # @mom
    #     records[3].ancestors.should == [@grandpa, @dad, @mom, @child]  # @child
    #   end

    #   it "should include ancestors in the correct order" do
    #     records = @klass.order("#{@klass.table_name}.id asc").includes(:ancestors)

    #     records[0].ancestors.should == [@grandpa]                      # @grandpa
    #     records[1].ancestors.should == [@grandpa, @dad]                # @dad
    #     records[2].ancestors.should == [@mom]                          # @mom
    #     records[3].ancestors.should == [@grandpa, @dad, @mom, @child]  # @child
    #   end
    # end
  end

  describe "models with separate link tables" do
    before(:each) do
      @klass = SeparateLinkModel
    end

    it_should_behave_like "DAG Model"
  end

  describe "models with unified link tables" do
    before(:each) do
      @klass = UnifiedLinkModel
    end

    it_should_behave_like "DAG Model"

    it "should create links that include the category type" do
      record = @klass.create!

      record.parent_links.first.category_type.should == @klass.name
      record.descendant_links.first.category_type.should == @klass.name
    end
  end
end
