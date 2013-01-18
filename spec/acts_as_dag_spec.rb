require 'spec_helper'

describe 'acts_as_dag' do
  shared_examples_for "DAG Model" do
    before(:each) do
      @klass.destroy_all # Because we're using sqlite3 and it doesn't support transactional specs (afaik)
    end
    
    describe "and" do
      before(:each) do
        @grandpa = @klass.create(:name => 'grandpa')
        @dad = @klass.create(:name => 'dad')
        @mom = @klass.create(:name => 'mom')
        @child = @klass.create(:name => 'child')
      end

      it "should be a root node immediately after saving" do
        @grandpa.parents.should be_empty
        @grandpa.root?.should be_true
      end

      it "should be descendant of itself immediately after saving" do
        @grandpa.descendants.should == [@grandpa]
      end

      it "should be ancestor of itself immediately after saving" do
        @grandpa.ancestors.should == [@grandpa]
      end

      it "should be able to add a child" do
        @grandpa.add_child(@dad)

        @grandpa.children.should == [@dad]
      end

      it "should be able to add a parent" do
        @child.add_parent(@dad)

        @child.parents.should == [@dad]
      end

      it "should be able to add multiple parents" do
        @child.add_parent(@dad)
        @child.add_parent(@mom)

        @child.parents.sort_by(&:id).should == [@dad, @mom].sort_by(&:id)
      end

      it "should be able to add multiple children" do
        @grandpa.add_child(@dad)
        @grandpa.add_child(@mom)

        @grandpa.children.sort_by(&:id).should == [@dad, @mom].sort_by(&:id)
      end

      it "should be able to add ancestors (top down)" do
        @grandpa.add_child(@dad)
        @dad.add_child(@child)

        @grandpa.children.should == [@dad]
        @grandpa.descendants.sort_by(&:id).should == [@grandpa, @dad, @child].sort_by(&:id)
        @dad.descendants.should == [@dad, @child]
        @dad.children.should == [@child]
      end

      it "should be able to add ancestors (bottom up)" do
        @dad.add_child(@child)
        @grandpa.add_child(@dad)

        @grandpa.children.should == [@dad]
        @grandpa.descendants.sort_by(&:id).should == [@grandpa, @dad, @child].sort_by(&:id)
        @dad.descendants.should == [@dad,@child]
        @dad.children.should == [@child]
      end
      
      it "should be able to test descent" do
        @dad.add_child(@child)
        @grandpa.add_child(@dad)

        @grandpa.ancestor_of?(@child).should be_true
        @child.descendant_of?(@grandpa).should be_true
        @child.ancestor_of?(@grandpa).should be_false
        @grandpa.descendant_of?(@child).should be_false
      end    
    end

    describe "reorganization" do
      before(:each) do
        @totem = @klass.create(:name => "totem")
        @totem_pole = @klass.create(:name => "totem pole")
        @big_totem_pole = @klass.create(:name => "big totem pole")
        @big_model_totem_pole = @klass.create(:name => "big model totem pole")
        @big_red_model_totem_pole = @klass.create(:name => "big red model totem pole")      
      end

      it "should reinitialize links and descendants after resetting the hierarchy" do
        @klass.reset_hierarchy
        @big_totem_pole.parents.should == []
        @big_totem_pole.children.should == []
        @big_totem_pole.ancestors.should == [@big_totem_pole]
        @big_totem_pole.descendants.should == [@big_totem_pole]
      end

      it "should be able to determine whether one category is an ancestor of the other by inspecting the name" do 
        ActsAsDAG::HelperMethods.should_descend_from?(@totem_pole, @big_totem_pole).should be_true
        ActsAsDAG::HelperMethods.should_descend_from?(@big_totem_pole, @totem_pole).should be_false
      end

      it "should be able to determine the number of matching words in two categories names" do 
        ActsAsDAG::HelperMethods.matching_word_count(@totem_pole, @big_totem_pole).should == 2
      end

      it "should arrange the categories correctly when not passed any arguments" do
        @klass.reorganize
        
        @totem.children.should == [@totem_pole]
        @totem_pole.children.should == [@big_totem_pole]
        @big_totem_pole.children.should == [@big_model_totem_pole]
        @big_model_totem_pole.children.should == [@big_red_model_totem_pole]
      end

      it "should arrange the categories correctly when passed a set of nodes to reorganize" do
        @klass.reorganize [@totem, @totem_pole, @big_totem_pole, @big_model_totem_pole, @big_red_model_totem_pole]
        
        @totem.reload.children.should == [@totem_pole]
        @totem_pole.reload.children.should == [@big_totem_pole]
        @big_totem_pole.reload.children.should == [@big_model_totem_pole]
        @big_model_totem_pole.reload.children.should == [@big_red_model_totem_pole]
      end

      it "should arrange the categories correctly when inserting a category into an existing chain" do
        @totem.add_child(@big_totem_pole)

        @klass.reorganize

        @totem.children.should == [@totem_pole]
        @totem_pole.children.should == [@big_totem_pole]
        @big_totem_pole.children.should == [@big_model_totem_pole]
        @big_model_totem_pole.reload.children.should == [@big_red_model_totem_pole]
      end
    
      it "should still work when there are categories that are permutations of each other" do
        @big_totem_pole_model = @klass.create(:name => "big totem pole model")

        @klass.reorganize [@totem, @totem_pole, @big_totem_pole, @big_model_totem_pole, @big_red_model_totem_pole, @big_totem_pole_model]

        @totem.children.should == [@totem_pole]
        @totem_pole.children.should == [@big_totem_pole]
        (@big_totem_pole.children - [@big_model_totem_pole, @big_totem_pole_model]).should == []
        @big_model_totem_pole.reload.children.should == [@big_red_model_totem_pole]
        @big_totem_pole_model.reload.children.should == [@big_red_model_totem_pole]
      end  

      describe "when there is a single long inheritance chain" do
        before(:each) do
          @totem.add_child(@totem_pole)
          @totem_pole.add_child(@big_totem_pole)
          @big_totem_pole.add_child(@big_model_totem_pole)
          @big_model_totem_pole.add_child(@big_red_model_totem_pole)
        end

        describe "and we are reorganizing the middle of the chain" do
          # Totem
          #   |
          # Totem Pole
          #  *|*       \
          #  *|*      Big Totem Pole
          #  *|*       /
          # Big Model Totem Pole
          #   |
          # Big Red Model Totem Pole
          #
          before(:each) do
            @totem_pole.add_child(@big_model_totem_pole)
          end

          it "should return multiple instances of descendants before breaking the old link" do
            @totem.descendants.sort_by(&:id).should == [@totem, @totem_pole, @big_totem_pole, @big_model_totem_pole, @big_model_totem_pole, @big_red_model_totem_pole, @big_red_model_totem_pole].sort_by(&:id)        
          end

          it "should return the correct inheritance chain after breaking the old link" do
            @totem_pole.remove_child(@big_model_totem_pole)

            @totem_pole.children.sort_by(&:id).should == [@big_totem_pole].sort_by(&:id)        
            @totem.descendants.sort_by(&:id).should == [@totem, @totem_pole, @big_totem_pole, @big_model_totem_pole, @big_red_model_totem_pole].sort_by(&:id)        
          end

          it "should return the correct inheritance chain after breaking the old link when there is are two ancestor root nodes" do
            pole = @klass.create(:name => "pole")
            @totem_pole.add_parent(pole)
            @totem_pole.remove_child(@big_model_totem_pole)

            pole.descendants.sort_by(&:id).should == [pole, @totem_pole, @big_totem_pole, @big_model_totem_pole, @big_red_model_totem_pole].sort_by(&:id)
            @totem_pole.children.sort_by(&:id).should == [@big_totem_pole].sort_by(&:id)
            @totem.descendants.sort_by(&:id).should == [@totem, @totem_pole, @big_totem_pole, @big_model_totem_pole, @big_red_model_totem_pole].sort_by(&:id)
          end
        end
      end    
    end

    describe "and two paths of the same length exist to the same node" do
      before(:each) do
        @grandpa = @klass.create(:name => 'grandpa')
        @dad = @klass.create(:name => 'dad')
        @mom = @klass.create(:name => 'mom')
        @child = @klass.create(:name => 'child')

        # nevermind the incest
        @grandpa.add_child(@dad)
        @dad.add_child(@child)
        @child.add_parent(@mom)
        @mom.add_parent(@grandpa)      
      end

      it "descendants should not return multiple instances of a child" do
        @grandpa.descendants.sort_by(&:id).should == [@grandpa, @dad, @mom, @child].sort_by(&:id)
      end      

      describe "and a link between parent and ancestor is removed" do 
        before(:each) do
          # the incest is undone!
          @dad.remove_parent(@grandpa)
        end

        it "should still return the correct ancestors" do
          @child.ancestors.sort_by(&:id).should == [@grandpa, @dad, @mom, @child].sort_by(&:id)
          @mom.ancestors.sort_by(&:id).should == [@grandpa, @mom].sort_by(&:id)
          @dad.ancestors.sort_by(&:id).should == [@dad].sort_by(&:id)
        end

        it "should still return the correct descendants" do
          @child.descendants.sort_by(&:id).should == [@child].sort_by(&:id)
          @mom.descendants.sort_by(&:id).should == [@mom, @child].sort_by(&:id)
          @dad.descendants.sort_by(&:id).should == [@dad, @child].sort_by(&:id)
          @grandpa.descendants.sort_by(&:id).should == [@grandpa, @mom, @child].sort_by(&:id)
        end      
      end
    end
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
      @klass.logger = Logger.new(STDOUT)
    end

    it_should_behave_like "DAG Model"

    it "should create links that include the category type" do
      record = @klass.create!

      record.parent_links.first.category_type.should == @klass.name
      record.descendant_links.first.category_type.should == @klass.name
    end
  end  
end