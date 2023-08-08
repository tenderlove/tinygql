# TinyGQL

Very experimental GraphQL parser.  It's mostly reusing the lexer from
[GraphQL-Ruby](https://github.com/rmosolgo/graphql-ruby), but the parser is a
hand-written recursive descent parser.

I want to target this at server side applications, so the parser eliminates some nice stuff for humans (namely line / column information, and it throws away comments).

Right now this code:

1. Only parses [ExecutableDefinitions](https://spec.graphql.org/June2018/#ExecutableDefinition) since the spec says "GraphQL services which only seek to provide GraphQL query execution may choose to only include ExecutableDefinition and omit the TypeSystemDefinition and TypeSystemExtension rules from Definition."
2. Doesn't know how to execute anything.  It just gives you an AST
3. Isn't used anywhere

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
