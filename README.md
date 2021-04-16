# ActsAsDAG [![Gem Version](https://badge.fury.io/rb/acts_as_dag.svg)](http://badge.fury.io/rb/acts_as_dag)

Adds Directed Acyclic Graph functionality to ActiveRecord

## Getting Started

### Gemfile

```ruby
gem 'acts_as_dag'
```

### Migration

```ruby
class CreateActsAsDagTables < ActiveRecord::Migration
  def change
    create_table "acts_as_dag_descendants", :force => true do |t|
      t.string :category_type
      t.references :ancestor
      t.references :descendant
      t.integer :distance
    end

    create_table "acts_as_dag_links", :force => true do |t|
      t.string :category_type
      t.references :parent
      t.references :child
    end
  end
end
```

### Usage

```ruby
class Person < ActiveRecord::Base
  acts_as_dag
end


# Defining links in an attributes hash
mom = Person.new(:name => 'Mom')
grandpa = Person.create(:name => 'Grandpa', :children => [mom])
grandpa.children #=> #<ActiveRecord::Associations::CollectionProxy [#<Person id: 1, name: "mom">]>

# Linking existing records manually
suzy = Person.create(:name => 'Suzy')
mom.add_child(suzy)
mom.children #=> #<ActiveRecord::Associations::CollectionProxy [#<Person id: 3, name: "suzy">]>
```

## Mutators

```
add_parent      Adds the given record(s) as a parent of the receiver. Accepts multiple arguments or an array.
add_child       Adds the given record(s) as a child of the receiver. Accepts multiple arguments or an array.
remove_parent   Removes the given record as a parent of the receiver. Accepts a single record.
remove_child    Removes the given record as a child of the receiver. Accepts a single record.
```


## Accessors

```
parent           Returns the parent of the record, nil for a root node
parent_id        Returns the id of the parent of the record, nil for a root node
root?            Returns true if the record is a root node, false otherwise
ancestor_ids     Returns a list of ancestor ids, starting with the root id and ending with the parent id
ancestors        Scopes the model on ancestors of the record
path_ids         Returns a list the path ids, starting with the root id and ending with the node's own id
path             Scopes model on path records of the record
children         Scopes the model on children of the record
child_ids        Returns a list of child ids
descendants      Scopes the model on direct and indirect children of the record
descendant_ids   Returns a list of a descendant ids
subtree          Scopes the model on descendants and itself
subtree_ids      Returns a list of all ids in the record's subtree
distance_to      Returns the minimum number of ancestors/descendants between two records, e.g. child.distance_to(grandpa) #=> 2
```

## Scopes

```
roots                   Nodes without parents
leaves                  Nodes without children
ancestors_of(node)      Ancestors of node, node can be either a record, id, scope, or array
children_of(node)       Children of node, node can be either a record, id, scope, or array
descendants_of(node)    Descendants of node, node can be either a record, id, scope, or array
path_of(node)           Node and ancestors of node, node can be either a record, id, scope, or array
subtree_of(node)        Subtree of node, node can be either a record, id, scope, or array
```


## Options

The default behaviour is to store data for all classes in the same two links and descendants tables.
The category_type column is used to filter out relationships for other classes. These options can be
used to choose which classes and tables store the graph data.

```
:link_class             The name of the class to use for storing parent-child relationships. Defaults to "#{self.name}Link", e.g. PersonLink
:link_table             The table the link class stores data in. Defaults to "acts_as_dag_links"
:descendant_class       The name of the class to use for storing ancestor-descendant relationships. Defaults to "#{self.name}Descendant", e.g PersonDescendant
:descendant_table       The table the descendant class stores data in. Defaults to "acts_as_dag_descendants"
:link_conditions        Conditions to use when fetching link and descendant records. Defaults to {:category_type => self.name}, e.g. {:category_type => 'Person'}
```

## Future development

### Mutators

```
remove_parent   Removes the given record(s) as a parent of the receiver. Accepts a multiple arguments or an array.
remove_child    Removes the given record(s) as a child of the receiver. Accepts a multiple arguments or an array.
```

### Accessors

```
root             Returns the root of the tree the record is in, self for a root node
root_id          Returns the id of the root of the tree the record is in
has_children?    Returns true if the record has any children, false otherwise
is_childless?    Returns true is the record has no children, false otherwise
siblings         Scopes the model on siblings of the record, the record itself is included*
sibling_ids      Returns a list of sibling ids
has_siblings?    Returns true if the record's parent has more than one child
is_only_child?   Returns true if the record is the only child of its parent
depth            Return the depth of the node, root nodes are at depth 0
```

### Scopes

```
siblings_of(node)       Siblings of node, node can be either a record or an id
```

### Remove deprecated functionality
This gem was extracted from an early project. Functionality required for that project found its way into the gem, but is only tangentially related to the generation of the DAG. This has been moved to the ActsAsDag::Deprecated module, and will be removed in a future version.

## Tests

`bundle exec rspec` to run tests.

## Credits

Thank you to the developers of the Ancestry gem for inspiring the list of accessors and scopes
