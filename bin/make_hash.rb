require "tinygql"

# Calculate a perfect hash for GraphQL keywords

def bits x
  count = 0
  while x > 0
    count += 1
    x >>= 1
  end
  count
end

# on is too short, and subscription is the longest.
# The lexer can easily detect them by length, so lets calculate a perfect
# hash for the rest.
kws = TinyGQL::Lexer::KEYWORDS - ["on"]
MASK = (1 << bits(kws.length)) - 1

prefixes = kws.map { |word| word[1, 2] }

# make sure they're unique
raise "Not unique" unless prefixes.uniq == prefixes

keys = prefixes.map { |prefix|
  prefix.bytes.reverse.inject(0) { |c, byte|
    c << 8 | byte
  }
}

shift = 32 - bits(kws.length) # use the top bits

c = 13
loop do
  z = keys.map { |k| ((k * c) >> shift) & MASK }
  break if z.uniq.length == z.length
  c += 1
end

table = kws.zip(keys).each_with_object([]) { |(word, k), o|
  hash = ((k * c) >> shift) & MASK
  o[hash] = word.upcase.to_sym
}

print "KW_LUT ="
pp table
puts <<-eomethod
def hash key
  (key * #{c}) >> #{shift} & #{sprintf("%#0x", MASK)}
end
eomethod
