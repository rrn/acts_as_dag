require 'spec_helper'

describe 'acts_as_dag' do
  shared_examples_for "DAG Model" do
    describe "reorganization" do
      let(:totem) { klass.create(:name => "totem") }
      let(:totem_pole) { klass.create(:name => "totem pole") }
      let(:big_totem_pole) { klass.create(:name => "big totem pole") }
      let(:big_model_totem_pole) { klass.create(:name => "big model totem pole") }
      let(:big_red_model_totem_pole) { klass.create(:name => "big red model totem pole") }

      before do
        # Rspec alone doesn't support transactional tests, so clear it all out between tests
        klass.destroy_all
        # Ensure the models exist
        totem; totem_pole; big_totem_pole; big_model_totem_pole; big_red_model_totem_pole
      end

      it "should be able to determine whether one category is an ancestor of the other by inspecting the name" do
        ActsAsDAG::Deprecated::HelperMethods.should_descend_from?(totem_pole, big_totem_pole).should be_truthy
        ActsAsDAG::Deprecated::HelperMethods.should_descend_from?(big_totem_pole, totem_pole).should be_falsy
      end

      it "should be able to determine the number of matching words in two categories names" do
        ActsAsDAG::Deprecated::HelperMethods.matching_word_count(totem_pole, big_totem_pole).should == 2
      end

      it "should arrange the categories correctly when not passed any arguments" do
        klass.reorganize

        totem.children.should == [totem_pole]
        totem_pole.children.should == [big_totem_pole]
        big_totem_pole.children.should == [big_model_totem_pole]
        big_model_totem_pole.children.should == [big_red_model_totem_pole]
      end

      it "should arrange the categories correctly when passed a set of nodes to reorganize" do
        klass.reorganize [totem, totem_pole, big_totem_pole, big_model_totem_pole, big_red_model_totem_pole]

        totem.reload.children.should == [totem_pole]
        totem_pole.reload.children.should == [big_totem_pole]
        big_totem_pole.reload.children.should == [big_model_totem_pole]
        big_model_totem_pole.reload.children.should == [big_red_model_totem_pole]
      end

      it "should arrange the categories correctly when inserting a category into an existing chain" do
        totem.add_child(big_totem_pole)

        klass.reorganize

        totem.children.should == [totem_pole]
        totem_pole.children.should == [big_totem_pole]
        big_totem_pole.children.should == [big_model_totem_pole]
        big_model_totem_pole.reload.children.should == [big_red_model_totem_pole]
      end

      it "should still work when there are categories that are permutations of each other" do
        big_totem_pole_model = klass.create(:name => "big totem pole model")

        klass.reorganize [totem, totem_pole, big_totem_pole, big_model_totem_pole, big_red_model_totem_pole, big_totem_pole_model]

        totem.children.should == [totem_pole]
        totem_pole.children.should == [big_totem_pole]
        (big_totem_pole.children - [big_model_totem_pole, big_totem_pole_model]).should == []
        big_model_totem_pole.reload.children.should == [big_red_model_totem_pole]
        big_totem_pole_model.reload.children.should == [big_red_model_totem_pole]
      end

      describe "when there is a single long inheritance chain" do
        before(:each) do
          totem.add_child(totem_pole)
          totem_pole.add_child(big_totem_pole)
          big_totem_pole.add_child(big_model_totem_pole)
          big_model_totem_pole.add_child(big_red_model_totem_pole)
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
            totem_pole.add_child(big_model_totem_pole)
          end

          it "should return multiple instances of descendants before breaking the old link" do
            totem.descendants.sort_by(&:id).should == [totem_pole, big_totem_pole, big_model_totem_pole, big_model_totem_pole, big_red_model_totem_pole, big_red_model_totem_pole].sort_by(&:id)
          end

          it "should return the correct inheritance chain after breaking the old link" do
            totem_pole.remove_child(big_model_totem_pole)

            totem_pole.children.sort_by(&:id).should == [big_totem_pole].sort_by(&:id)
            totem.descendants.sort_by(&:id).should == [totem_pole, big_totem_pole, big_model_totem_pole, big_red_model_totem_pole].sort_by(&:id)
          end

          it "should return the correct inheritance chain after breaking the old link when there is are two ancestor root nodes" do
            pole = klass.create(:name => "pole")
            totem_pole.add_parent(pole)
            totem_pole.remove_child(big_model_totem_pole)

            pole.descendants.sort_by(&:id).should == [totem_pole, big_totem_pole, big_model_totem_pole, big_red_model_totem_pole].sort_by(&:id)
            totem_pole.children.sort_by(&:id).should == [big_totem_pole].sort_by(&:id)
            totem.descendants.sort_by(&:id).should == [totem_pole, big_totem_pole, big_model_totem_pole, big_red_model_totem_pole].sort_by(&:id)
          end
        end
      end
    end
  end

  describe "models with separate link tables" do
    let(:klass) { SeparateLinkModel }

    it_should_behave_like "DAG Model"
  end

  describe "models with unified link tables" do
    let(:klass) { UnifiedLinkModel }

    it_should_behave_like "DAG Model"
  end
end
