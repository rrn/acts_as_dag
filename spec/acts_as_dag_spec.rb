require 'spec_helper'

describe 'acts_as_dag' do
  before do
    klass.destroy_all # Because we're using sqlite3 and it doesn't support transactional specs (afaik)
  end

  shared_examples_for "DAG Model" do
    let (:grandpa) { klass.create(:name => 'grandpa') }
    let (:dad) { klass.create(:name => 'dad') }
    let (:mom) { klass.create(:name => 'mom') }
    let (:suzy) { klass.create(:name => 'suzy') }
    let (:billy) { klass.create(:name => 'billy') }

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

      it "returns no duplicates when there are multiple paths to the same descendant" do
        grandpa.add_child(mom, dad)
        billy.add_parent(mom, dad)

        expect(grandpa.descendants).to eq(grandpa.descendants.uniq)
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

      it "returns no duplicates when there are multiple paths to the same descendant" do
        grandpa.add_child(mom, dad)
        billy.add_parent(mom, dad)

        expect(grandpa.subtree).to eq(grandpa.subtree.uniq)
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
        mom.add_child(billy)
        dad.add_child(billy)
        expect(billy.ancestors).to eq([grandpa, mom, dad])
      end

      it "returns no duplicates when there are multiple paths to the same ancestor" do
        grandpa.add_child(mom, dad)
        billy.add_parent(mom, dad)

        expect(billy.ancestors).to eq(billy.ancestors.uniq)
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

      it "returns no duplicates when there are multiple paths to the same ancestor" do
        grandpa.add_child(mom, dad)
        billy.add_parent(mom, dad)

        expect(billy.path).to eq(billy.path.uniq)
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

      it "includes all ancestors and descendants of the receiver" do
        mom.add_child(suzy, billy)
        mom.add_parent(grandpa)
        expect(mom.lineage).to include(grandpa, suzy, billy)
      end

      it "return ancestors and descendants of the receiver in the order they would be if called separately" do
        mom.add_child(suzy, billy)
        mom.add_parent(grandpa)
        expect(mom.lineage).to eq([grandpa, suzy, billy])
      end
    end

    describe '::children' do
      it "returns an ActiveRecord::Relation" do
        expect(klass.children).to be_an(ActiveRecord::Relation)
      end

      it "returns records that have at least 1 parent" do
        mom.add_parent(grandpa)
        mom.add_child(suzy)
        expect(klass.children).to include(mom, suzy)
      end

      it "doesn't returns records without parents" do
        mom.add_parent(grandpa)
        mom.add_child(suzy)
        expect(klass.children).not_to include(grandpa)
      end

      it "does not return duplicate records, regardless of the number of parents" do
        suzy.add_parent(mom, dad)
        expect(klass.children).to eq([suzy])
      end
    end

    describe '::parent_records' do
      it "returns an ActiveRecord::Relation" do
        expect(klass.parent_records).to be_an(ActiveRecord::Relation)
      end

      it "returns records that have at least 1 child" do
        mom.add_parent(grandpa)
        mom.add_child(suzy)
        expect(klass.parent_records).to include(grandpa, mom)
      end

      it "doesn't returns records without children" do
        mom.add_parent(grandpa)
        mom.add_child(suzy)
        expect(klass.parent_records).not_to include(suzy)
      end

      it "does not return duplicate records, regardless of the number of children" do
        mom.add_child(suzy, billy)
        expect(klass.parent_records).to eq([mom])
      end
    end

    describe '#ancestors_of' do
      it "returns an ActiveRecord::Relation" do
        expect(klass.ancestors_of(suzy)).to be_an(ActiveRecord::Relation)
      end

      it "doesn't include the given record" do
        expect(klass.ancestors_of(suzy)).not_to include(suzy)
      end

      it "returns records that are ancestors of the given record" do
        suzy.add_parent(mom, dad)
        expect(klass.ancestors_of(suzy)).to include(mom, dad)
      end

      it "doesn't return records that are not ancestors of the given record" do
        suzy.add_parent(mom)
        expect(klass.ancestors_of(suzy)).not_to include(dad)
      end

      it "returns records that are ancestors of the given record id" do
        suzy.add_parent(mom, dad)
        expect(klass.ancestors_of(suzy.id)).to include(mom, dad)
      end
    end

    describe '#descendants_of' do
      it "returns an ActiveRecord::Relation" do
        expect(klass.descendants_of(grandpa)).to be_an(ActiveRecord::Relation)
      end

      it "doesn't include the given record" do
        expect(klass.descendants_of(grandpa)).not_to include(grandpa)
      end

      it "returns records that are descendants of the given record" do
        grandpa.add_child(mom, dad)
        expect(klass.descendants_of(grandpa)).to include(mom, dad)
      end

      it "doesn't return records that are not descendants of the given record" do
        grandpa.add_child(mom)
        expect(klass.descendants_of(grandpa)).not_to include(dad)
      end

      it "returns records that are descendants of the given record id" do
        grandpa.add_child(mom, dad)
        expect(klass.descendants_of(grandpa.id)).to include(mom, dad)
      end
    end

    describe '#path_of' do
      it "returns an ActiveRecord::Relation" do
        expect(klass.path_of(suzy)).to be_an(ActiveRecord::Relation)
      end

      it "returns records that are path-members of the given record" do
        suzy.add_parent(mom, dad)
        expect(klass.path_of(suzy)).to include(mom, dad, suzy)
      end

      it "doesn't return records that are not path-members of the given record" do
        suzy.add_parent(mom)
        expect(klass.path_of(suzy)).not_to include(dad)
      end

      it "returns records that are path-members of the given record id" do
        suzy.add_parent(mom, dad)
        expect(klass.path_of(suzy.id)).to include(mom, dad, suzy)
      end
    end

    describe '#subtree_of' do
      it "returns an ActiveRecord::Relation" do
        expect(klass.subtree_of(grandpa)).to be_an(ActiveRecord::Relation)
      end

      it "returns records that are subtree-members of the given record" do
        grandpa.add_child(mom, dad)
        expect(klass.subtree_of(grandpa)).to include(grandpa, mom, dad)
      end

      it "doesn't return records that are not subtree-members of the given record" do
        grandpa.add_child(mom)
        expect(klass.subtree_of(grandpa)).not_to include(dad)
      end

      it "returns records that are subtree-members of the given record id" do
        grandpa.add_child(mom, dad)
        expect(klass.subtree_of(grandpa.id)).to include(grandpa, mom, dad)
      end
    end

    describe '#destroy' do
      it "destroys associated hierarchy-tracking records" do
        mom.add_parent(grandpa)
        mom.add_child(suzy)

        mom.destroy

        expect(mom.ancestor_links).to contain_exactly
        expect(mom.path_links).to contain_exactly
        expect(mom.parent_links).to contain_exactly
        expect(mom.child_links).to contain_exactly
      end
    end

    describe '#parents=' do
      before { suzy.parents = [mom, dad] }

      it "sets the receiver's parents to the given array" do
        expect(suzy.parents).to eq([mom, dad])
      end

      it "updates the ancestors of the receiver" do
        expect(suzy.ancestors).to eq([mom, dad])
      end

      it "unsets the receiver's parents when given an empty array" do
        suzy.parents = []
        expect(suzy.parents).to contain_exactly
      end

      it "updates the ancestors of the receivers when given an empty array" do
        suzy.parents = []
        expect(suzy.ancestors).to contain_exactly
      end
    end

    describe '#children=' do
      before { grandpa.children = [mom, dad] }

      it "sets the receiver's children to the given array" do
        expect(grandpa.children).to eq([mom, dad])
      end

      it "updates the descendants of the receiver" do
        expect(grandpa.descendants).to eq([mom, dad])
      end

      it "unsets the receiver's children when given an empty array" do
        grandpa.children = []
        expect(grandpa.children).to contain_exactly
      end

      it "updates the descendants of the receivers when given an empty array" do
        grandpa.children = []
        expect(grandpa.descendants).to contain_exactly
      end
    end

    describe '#parent_ids=' do
      before { suzy.parent_ids = [mom.id, dad.id] }

      it "sets the receiver's parents to the given array" do
        expect(suzy.parents).to eq([mom, dad])
      end

      it "updates the ancestors of the receiver" do
        expect(suzy.ancestors).to eq([mom, dad])
      end

      it "unsets the receiver's parents when given an empty array" do
        suzy.parents = []
        expect(suzy.parents).to contain_exactly
      end

      it "updates the ancestors of the receivers when given an empty array" do
        suzy.parents = []
        expect(suzy.ancestors).to contain_exactly
      end
    end

    describe '#child_ids=' do
      before { grandpa.child_ids = [mom.id, dad.id] }

      it "sets the receiver's children to the given array" do
        expect(grandpa.children).to eq([mom, dad])
      end

      it "updates the descendants of the receiver" do
        expect(grandpa.descendants).to eq([mom, dad])
      end

      it "unsets the receiver's children when given an empty array" do
        grandpa.children = []
        expect(grandpa.children).to contain_exactly
      end

      it "updates the descendants of the receivers when given an empty array" do
        grandpa.children = []
        expect(grandpa.descendants).to contain_exactly
      end
    end

    describe '#create' do
      it "sets the receiver's children to the given array" do
        record = klass.create!(:children => [mom, dad])
        expect(record.children).to contain_exactly(mom, dad)
      end

      it "updates the descendants of the receiver" do
        record = klass.create!(:children => [mom, dad])
        record.reload
        expect(record.descendants).to contain_exactly(mom, dad)
      end

      it "sets the receiver's parents to the given array" do
        record = klass.create!(:parents => [mom, dad])
        expect(record.parents).to contain_exactly(mom, dad)
      end

      it "updates the ancestors of the receiver" do
        record = klass.create!(:parents => [mom, dad])
        record.reload
        expect(record.ancestors).to contain_exactly(mom, dad)
      end
    end

    describe '::reset_hierarchy' do
      it "reinitialize links and descendants after resetting the hierarchy" do
        mom.add_parent(grandpa)
        mom.add_child(suzy)

        klass.reset_hierarchy
        expect(mom.parents).to contain_exactly()
        expect(mom.children).to contain_exactly()
        expect(mom.path).to contain_exactly(mom)
        expect(mom.subtree).to contain_exactly(mom)
      end
    end

    describe '#ancestor_links' do
      it "doesn't include a link to the receiver" do
        expect(mom.ancestor_links).to contain_exactly
      end
    end

    describe '#path_links' do
      it "includes a link to the receiver" do
        expect(mom.path_links.first.descendant).to eq(mom)
      end
    end

    describe '#descendant_links' do
      it "doesn't include a link to the receiver" do
        expect(mom.descendant_links).to contain_exactly
      end
    end

    describe '#subtree_links' do
      it "includes a link to the receiver" do
        expect(mom.subtree_links.first.descendant).to eq(mom)
      end
    end



    context "When two paths of the same length exist to the same node and a link between parent and ancestor is removed" do
      before do
        grandpa.add_child(mom, dad)
        suzy.add_parent(mom, dad)
      end

      describe '#remove_parent' do
        it "updates the ancestor links correctly" do
          dad.remove_parent(grandpa)
          expect(suzy.ancestors).to contain_exactly(grandpa, dad, mom)
          expect(mom.ancestors).to contain_exactly(grandpa)
          expect(dad.ancestors).to contain_exactly()
        end

        it "updates the descendant links correctly" do
          dad.remove_parent(grandpa)
          expect(suzy.descendants).to contain_exactly()
          expect(mom.descendants).to contain_exactly(suzy)
          expect(dad.descendants).to contain_exactly(suzy)
          expect(grandpa.descendants).to contain_exactly(mom, suzy)
        end
      end
    end

    # describe "Includes, Eager-Loads, and Preloads" do
    #   before(:each) do
    #     dad.add_parent(grandpa)
    #     billy.add_parent(dad, mom)
    #   end

    #   it "should preload path in the correct order" do
    #     records = klass.order("#{klass.table_name}.id asc").preload(:path)

    #     records[0].path.should == [grandpa]                      # grandpa
    #     records[1].path.should == [grandpa, dad]                # dad
    #     records[2].path.should == [mom]                          # mom
    #     records[3].path.should == [grandpa, dad, mom, billy]  # billy
    #   end

    #   it "should eager_load path in the correct order" do
    #     records = klass.order("#{klass.table_name}.id asc").eager_load(:path)

    #     records[0].path.should == [grandpa]                      # grandpa
    #     records[1].path.should == [grandpa, dad]                # dad
    #     records[2].path.should == [mom]                          # mom
    #     records[3].path.should == [grandpa, dad, mom, billy]  # billy
    #   end

    #   it "should include path in the correct order" do
    #     records = klass.order("#{klass.table_name}.id asc").includes(:path)

    #     records[0].path.should == [grandpa]                      # grandpa
    #     records[1].path.should == [grandpa, dad]                # dad
    #     records[2].path.should == [mom]                          # mom
    #     records[3].path.should == [grandpa, dad, mom, billy]  # billy
    #   end
    # end
  end

  describe "models with separate link tables" do
    let(:klass) { SeparateLinkModel }

    it_should_behave_like "DAG Model"
  end

  describe "models with unified link tables" do
    let(:klass) { UnifiedLinkModel }

    it_should_behave_like "DAG Model"

    it "should create links that include the category type" do
      record = klass.create!

      expect(record.parent_links.first.category_type).to eq(klass.name)
      expect(record.subtree_links.first.category_type).to eq(klass.name)
    end
  end
end
