# TinyGQL

Very experimental GraphQL parser.  It's mostly reusing the lexer from
[GraphQL-Ruby](https://github.com/rmosolgo/graphql-ruby), but the parser is a
hand-written recursive descent parser.

I want to target this at server side applications, so the parser eliminates some nice stuff for humans (namely line / column information, and it throws away comments).

Right now this code:

1. Doesn't know how to execute anything.  It just gives you an AST
2. Isn't used anywhere (except in your heart, *but hopefully in production someday!)

## Usage

You can get an AST like this:

```ruby
ast = TinyGQL.parse "{ cool }"
```

The AST is iterable, so you can use the each method:

```ruby
ast = TinyGQL.parse "{ cool }"
ast.each do |node|
  p node.class
end
```

Nodes have predicate methods, so if you want to find particular nodes just use a predicate:

```ruby
ast = TinyGQL.parse "{ cool }"
p ast.find_all(&:field?).map(&:name) # => ["cool"]
```

If you need a more advanced way to iterate nodes, you can use a visitor:

```ruby
class Viz
  include TinyGQL::Visitors::Visitor

  def handle_field obj
    p obj.name # => cool
    super
  end
end

ast = TinyGQL.parse "{ cool }"
ast.accept(Viz.new)
```

If you would like a functional way to collect data from the tree, use the `Fold` module:

```ruby
module Fold
  extend TinyGQL::Visitors::Fold

  def self.handle_field obj, seed
    super(obj, seed + [obj.name])
  end
end

ast = TinyGQL.parse "{ neat { cool } }"
p ast.fold(Fold, []) # => ["neat", "cool"]
```

## LICENSE:

I've licensed this code as Apache 2.0, but the lexer is from [GraphQL-Ruby](https://github.com/rmosolgo/graphql-ruby/blob/772734dfcc7aa0513c867259912474ef0ba799c3/lib/graphql/language/lexer.rb) and is under the MIT license.
