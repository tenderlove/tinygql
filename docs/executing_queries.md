# Executing queries

This walks through serving GraphQL requests with TinyGQL: generating a
parser from a schema, implementing scalars and resolvers, and handling
requests.

There are three steps for each request:

1. **Parse** the query with the generated parser.  This also validates it
   against the schema and coerces its literals.
2. **Coerce** the request's JSON variables to Ruby values.
3. **Execute** the operation, calling your resolvers.

## The schema

A small bookstore, with a custom scalar, an enum, an interface, input
objects, and a mutation:

```graphql
"A calendar date, as an ISO 8601 string like 2026-11-02"
scalar Date

enum Genre { FICTION HISTORY SCIENCE }

interface Node { id: ID! }

type Author implements Node {
  id: ID!
  name: String!
  books(first: Int = 10): [Book!]!
}

type Book implements Node {
  id: ID!
  title: String!
  genre: Genre!
  published: Date
  author: Author!
}

input BookFilter {
  genre: Genre
  publishedAfter: Date
}

input AddBookInput {
  title: String!
  authorId: ID!
  genre: Genre = FICTION
}

type Query {
  books(filter: BookFilter, first: Int = 20): [Book!]!
  node(id: ID!): Node
}

type Mutation {
  addBook(input: AddBookInput!): Book!
}
```

## Generating the parser

Generate the parser ahead of time, for example from a Rake task, and
check it in or build it during deploys.  Regenerate it whenever the schema
changes.

```ruby
require "tinygql"
require "tinygql/generator"

schema = TinyGQL.parse_schema(File.read("schema.graphql"))
File.write "book_parser.rb", TinyGQL::Generator.new(schema).generate("BookParser")
```

`book_parser.rb` defines `BookParser`, plus three classes nested inside it
that you subclass:

- `BookParser::Scalars` coerces scalar values.
- `BookParser::Resolvers` resolves fields.
- `BookParser::Executor` runs operations.  You don't use it directly.

It also defines classes for input values:

- `BookParser::InputObjects` has one class for each input object, like
  `InputObjects::BookFilter`.
- `BookParser::Arguments` has one class for each field with arguments,
  like `Arguments::Query_books`.

## Scalars

The built-in scalars (`Int`, `Float`, `String`, `Boolean`, and `ID`) work
out of the box.  Each custom scalar needs three methods.  Until you
implement them, they raise `NotImplementedError`.

| Method | Called with | When |
| --- | --- | --- |
| `coerce_literal_X(kind, text)` | A literal in the query, like `"2000-01-01"`, and its kind: `:STRING`, `:INT`, `:FLOAT`, `:BOOLEAN`, `:ENUM`, `:LIST`, or `:OBJECT` | While parsing |
| `coerce_value_X(value)` | A decoded JSON value from the request's variables | While coercing variables |
| `coerce_result_X(value)` | What a resolver returned | While executing |

The coerce methods raise `InvalidValue` for values they don't accept.

```ruby
require "date"
require_relative "book_parser"

class AppScalars < BookParser::Scalars
  # Literals in the query, like `publishedAfter: "2000-01-01"`
  def coerce_literal_Date kind, text
    raise InvalidValue, "Date must be a string" unless kind == :STRING
    coerce_value_Date text
  end

  # Values in the request's JSON variables
  def coerce_value_Date value
    raise InvalidValue, "Date must be a string" unless value.is_a?(String)
    Date.iso8601(value)
  rescue Date::Error
    raise InvalidValue, "Invalid Date #{value}"
  end

  # Values resolvers return
  def coerce_result_Date value
    value.iso8601
  end
end
```

## Resolvers

Every field has a resolver method named after its type and field, like
`Book_title`.  Resolvers are called with these arguments:

- `obj`: the parent object.  For root fields, this is the `root:` passed
  to `execute`.
- `args`: the field's arguments, as an instance of its `Arguments` class.
  For fields without arguments, `args` is `nil`.
- `context`: whatever you passed to `execute` as `context:`.

By default, a resolver calls the field's name on the object, so
`Book_title` returns `obj.title`.  Override only the fields that need
something else.

Interfaces and unions need a `resolve_type_X(obj, context)` method that
returns the name of the object's type.

```ruby
Author = Struct.new(:id, :name)
Book = Struct.new(:id, :title, :genre, :published, :author_id)

AUTHORS = [Author.new("1", "Ursula K. Le Guin"), Author.new("2", "Mary Beard")]
BOOKS = [
  Book.new("10", "The Dispossessed", :FICTION, Date.new(1974, 5, 1), "1"),
  Book.new("11", "A Wizard of Earthsea", :FICTION, Date.new(1968, 11, 1), "1"),
  Book.new("12", "SPQR", :HISTORY, Date.new(2015, 10, 20), "2"),
]

class AppResolvers < BookParser::Resolvers
  def Query_books obj, args, context
    books = BOOKS
    if (filter = args.filter)
      books = books.select { |b| b.genre.name == filter.genre } if filter.genre
      books = books.select { |b| b.published > filter.publishedAfter } if filter.publishedAfter
    end
    books.first(args.first)
  end

  def Query_node obj, args, context
    (AUTHORS + BOOKS).find { |n| n.id == args.id }
  end

  # These two return Lazies, see "Batching with loaders" below
  def Author_books author, args, context
    context.books_by_author.load([author.id, args.first])
  end

  def Book_author book, args, context
    context.authors.load(book.author_id)
  end

  def Mutation_addBook obj, args, context
    raise TinyGQL::ExecutionError, "Not allowed" unless context.admin
    input = args.input
    book = Book.new((BOOKS.length + 10).to_s, input.title, input.genre.to_sym, nil, input.authorId)
    BOOKS << book
    book
  end

  def resolve_type_Node obj, context
    obj.is_a?(Book) ? "Book" : "Author"
  end
end
```

Some things to note in this example:

- `Book_id`, `Book_title`, `Book_genre`, `Book_published`, `Author_id`, and
  `Author_name` use the default resolver.
- Enum values can be returned as Strings or Symbols.  `:FICTION` becomes
  `"FICTION"`.
- Input values arrive coerced.  `filter.publishedAfter` is a `Date`, and
  `input.genre` is `"FICTION"` when the request leaves it out, because
  that's its default in the schema.

## Arguments and input objects

`args` isn't the request's JSON.  It holds the arguments written on that
one field in the query.  Each argument comes from one of three places:

- a literal in the query
- a variable, taken from the request's `"variables"`
- the argument's default in the schema

For the first request below, `Query_books` gets:

```ruby
args.first                 # => 20, the default
args.filter                # => #<BookParser::InputObjects::BookFilter ...>
args.filter.genre          # => "FICTION", from $genre
args.filter.publishedAfter # => #<Date: 1970-01-01>, from $after
```

The generated classes are frozen, and have a reader for each field:

```ruby
module InputObjects
  class BookFilter
    attr_reader :genre #: String?
    attr_reader :publishedAfter #: untyped

    #: (String?, untyped) -> void
    def initialize f0, f1
      @genre = f0
      @publishedAfter = f1
      freeze
    end
  end
end

module Arguments
  class Query_books
    attr_reader :filter #: InputObjects::BookFilter?
    attr_reader :first #: Integer?

    # ...
  end
end
```

Arguments and input object fields that aren't given, and don't have a
default, are `nil`.  Lists are frozen Arrays.

The initializers take values in schema order.  You can call them yourself
to test resolvers, like
`AppResolvers.new.Query_books(nil, BookParser::Arguments::Query_books.new(nil, 2), RequestContext.new)`.

Field names become readers, so the generator rejects input fields and
arguments that would replace one of `Object`'s methods, like `hash` or
`class`.  Ruby keywords are fine: `args.in` and `args.end` work.

## Batching with loaders

Resolving `{ books { author { name } } }` one author at a time makes one
lookup per book.  To batch them, a resolver returns a `TinyGQL::Lazy` from
a loader instead of a value.  The executor sets it aside and finishes the
rest of the response.  Then it asks the lazies for their values, and the
first lazy from each loader loads every key that loader was given.

A loader subclasses `TinyGQL::Loader` and implements `perform`.  `perform`
gets the keys and calls `fulfill` for each one:

```ruby
class AuthorLoader < TinyGQL::Loader
  private

  def perform ids
    puts "loading authors #{ids.inspect}"
    ids.each { |id| fulfill id, AUTHORS.find { |a| a.id == id } }
  end
end

# Keys are [author_id, first] pairs
class BooksByAuthorLoader < TinyGQL::Loader
  private

  def perform keys
    puts "loading books for #{keys.inspect}"
    keys.each do |key|
      author_id, first = key
      fulfill key, BOOKS.select { |b| b.author_id == author_id }.first(first)
    end
  end
end
```

Loaders cache what they load, so make new ones for each request.  There's
no global registry; keep them on the context you pass to `execute`:

```ruby
class RequestContext
  attr_reader :admin, :authors, :books_by_author

  def initialize admin: false
    @admin = admin
    @authors = AuthorLoader.new
    @books_by_author = BooksByAuthorLoader.new
  end
end
```

With those, this request:

```json
{ "query": "{ books { title author { name books { title } } } }" }
```

loads in two batches, one for each depth:

```
loading authors ["1", "2"]
loading books for [["1", 10], ["2", 10]]
```

Some details about lazies:

- **Where they can go:** a lazy can stand in for any value: a field's
  value, a list item, or the value of another lazy.  `load_many(keys)`
  returns an Array of lazies for a list field.
- **Transforming results:** the executor can't change a lazy's value
  after it loads, so anything the result depends on goes in the key.
  `Author_books` needs `first`, so its key is `[author.id, args.first]`.
- **Errors:** if `perform` raises `TinyGQL::ExecutionError`, every field
  waiting on that batch gets the error.  Nulls bubble up as they do for
  other values, even though the parent objects were already written.  If
  `perform` doesn't fulfill a key, `TinyGQL::Loader::BrokenError` is
  raised.  That's a bug in the loader, so it isn't caught.
- **Mutations:** each mutation field's lazies are loaded before the next
  field runs, so mutations still happen in order.

## Handling a request

```ruby
require "json"

SCALARS = AppScalars.new
RESOLVERS = AppResolvers.new

def handle body, context = RequestContext.new
  request = JSON.parse(body)
  op = request["operationName"]

  doc = BookParser.parse(request["query"], scalars: SCALARS)
  variables = BookParser.coerce(doc, request["variables"], op: op, scalars: SCALARS)
  BookParser.execute(doc, variables, resolvers: RESOLVERS, op: op, context: context, scalars: SCALARS)
rescue TinyGQL::ExecutableParser::UnexpectedToken,
       TinyGQL::ValidatingParser::ValidationError,
       TinyGQL::Inputs::Error => e
  JSON.generate({ "errors" => [{ "message" => e.message }] })
end
```

`execute` returns the response as a JSON String, an object with `"data"`,
and with `"errors"` if any field failed.  The executor writes the JSON as it
goes, without building a Hash of the result first.

To write the response somewhere else, pass `out:`, anything with `<<`,
like an IO, a StringIO or a String to append to.  `execute` returns `out`:

```ruby
BookParser.execute(doc, variables, resolvers: RESOLVERS, scalars: SCALARS, out: socket)
```

The response is written to `out` once execution is done, not while it
runs: a null in a non-null field can still replace JSON that was already
written, up to the nearest field that can be null, or all of `"data"`.

Pass the same Scalars instance to `parse`, `coerce`, and `execute`.
`execute` also takes `root:`, the object passed to root field resolvers.
It defaults to `nil`.

Parsed documents are frozen, so you can cache them by query string and
skip parsing for repeated queries.  Variables still need to be coerced for
each request.

## Example requests

### A query with variables

```json
{
  "query": "query Books($genre: Genre, $after: Date) { books(filter: { genre: $genre, publishedAfter: $after }) { id title published author { name } } }",
  "operationName": "Books",
  "variables": { "genre": "FICTION", "after": "1970-01-01" }
}
```

```json
{
  "data": {
    "books": [
      {
        "id": "10",
        "title": "The Dispossessed",
        "published": "1974-05-01",
        "author": { "name": "Ursula K. Le Guin" }
      }
    ]
  }
}
```

### An interface, with fragments and an argument default

`$id` is an `ID`, so the number `1` is coerced to `"1"`.

```json
{
  "query": "query($id: ID!) { node(id: $id) { __typename id ... on Author { name books(first: 1) { title genre } } } }",
  "variables": { "id": 1 }
}
```

```json
{
  "data": {
    "node": {
      "__typename": "Author",
      "id": "1",
      "name": "Ursula K. Le Guin",
      "books": [
        { "title": "The Dispossessed", "genre": "FICTION" }
      ]
    }
  }
}
```

### A mutation

```json
{
  "query": "mutation Add($input: AddBookInput!) { addBook(input: $input) { id title genre author { name } } }",
  "variables": { "input": { "title": "Pompeii", "authorId": "2" } }
}
```

With `context` set to `RequestContext.new(admin: true)`:

```json
{
  "data": {
    "addBook": {
      "id": "13",
      "title": "Pompeii",
      "genre": "FICTION",
      "author": { "name": "Mary Beard" }
    }
  }
}
```

Without it, the resolver raises `TinyGQL::ExecutionError`.  `addBook` is
non-null, so the null goes up to `data`:

```json
{
  "data": null,
  "errors": [
    { "message": "Not allowed", "path": ["addBook"] }
  ]
}
```

## Introspection

`__schema` and `__type` work like other fields.  The generator builds the
schema's introspection results into the parser, as frozen
`TinyGQL::Introspection` objects in the `Introspection` module, so
introspection doesn't touch your resolvers or data.  The results include
descriptions, `@deprecated` reasons, `@specifiedBy` URLs, `@oneOf`, and
the schema's directive definitions.

`Query___schema` and `Query___type` are ordinary resolvers, so you can
override them, for example to turn introspection off:

```ruby
class AppResolvers < BookParser::Resolvers
  def Query___schema obj, args, context
    raise TinyGQL::ExecutionError, "Introspection is disabled"
  end

  def Query___type obj, args, context
    nil
  end
end
```

## Errors

Errors come from two places.

**Request errors** are raised before execution, by `parse` and `coerce`.
Rescue them and respond with the message, as `handle` does above:

| Error | Raised for |
| --- | --- |
| `TinyGQL::ExecutableParser::UnexpectedToken` | Syntax errors |
| `TinyGQL::ValidatingParser::ValidationError` | Queries that don't fit the schema |
| `TinyGQL::Inputs::Error` | Variables that don't fit, or an unknown `operationName` |

For example, a field that isn't in the schema:

```json
{ "query": "{ books { id isbn } }" }
```

```json
{ "errors": [{ "message": "Field isbn does not exist on Book line: 1" }] }
```

A variable that the scalar rejects:

```json
{
  "query": "query($after: Date) { books(filter: { publishedAfter: $after }) { id } }",
  "variables": { "after": "last tuesday" }
}
```

```json
{ "errors": [{ "message": "Invalid value for variable $after: Invalid Date last tuesday" }] }
```

**Field errors** happen during execution:

- a resolver raises `TinyGQL::ExecutionError`
- a resolver returns `nil` for a non-null field
- a resolver returns a value that doesn't fit the field's type, like an
  unknown enum value or a value without `each` for a list

The field becomes `null`, and the error goes into `"errors"` with the
field's `path`.  If the field is non-null, its parent becomes null
instead, up to the nearest field that can be null, or up to `data`.

Other exceptions, like a `NoMethodError` in a resolver, are not caught.
They propagate out of `execute`, so bugs aren't hidden in the response.

## Not supported yet

- Subscriptions.
- Locations in errors.
