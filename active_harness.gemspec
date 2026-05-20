Gem::Specification.new do |spec|
  spec.name          = "active_harness"
  spec.version       = "0.2.2"
  spec.authors       = ["the-teacher"]
  spec.email         = ["the-teacher@github.com"]
  spec.homepage      = "https://github.com/the-teacher/active_harness"
  spec.summary       = "DSL for describing and running AI agents with safety layers"
  spec.license       = "MIT"

  spec.files         = Dir["lib/**/*"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 2.6"

  spec.add_dependency "concurrent-ruby", "~> 1.3"
end
