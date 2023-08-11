require "vernier"

Vernier.trace(out: "time_profile.json") {
  require_relative "bench"
}
