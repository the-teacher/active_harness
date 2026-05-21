GEM_NAME    = active_harness
GEM_VERSION = $(shell ruby -e "load 'active_harness.gemspec'; puts Gem::Specification.load('active_harness.gemspec').version")
GEM_FILE    = $(GEM_NAME)-$(GEM_VERSION).gem

# Build the gem into pkg/
build:
	gem build $(GEM_NAME).gemspec

# Publish to RubyGems.org
pub:
	make build
	gem push $(GEM_FILE)
	make clean

push:
	make pub

public:
	make pub

# Remove built gem artifacts
clean:
	rm -rf *.gem

# Show download stats from RubyGems.org API
stats:
	@curl -s https://rubygems.org/api/v1/gems/$(GEM_NAME).json | \
	  ruby -rjson -e 'd=JSON.parse(ARGF.read); puts "version:    " + d["version"]; puts "downloads:  " + d["version_downloads"].to_s + " (this version)"; puts "total:      " + d["downloads"].to_s + " (all versions)"'

# Commit and push README changes
readme:
	git add -A && git commit -m "Readme" && git push origin master

# Commit all changes, create a version tag, push branch + tag, then publish
release:
	@V=$$(ruby -e "load 'active_harness.gemspec'; puts Gem::Specification.load('active_harness.gemspec').version"); \
	git add -A && \
	git commit -m "v$$V" && \
	git tag "v$$V" && \
	git push origin master && \
	git push origin "v$$V"
	make pub

# Bump patch version:  0.2.0 → 0.2.1
up:
	@ruby -i -e ' \
	  src = ARGF.read; \
	  src.sub!(/spec\.version\s*=\s*"(\d+)\.(\d+)\.(\d+)"/) { \
	    "spec.version       = \"#{$$1}.#{$$2}.#{$$3.to_i + 1}\"" \
	  }; \
	  print src \
	' active_harness.gemspec
	@echo "version → $$(ruby -e "load 'active_harness.gemspec'; puts Gem::Specification.load('active_harness.gemspec').version")"
	make release

# Bump minor version:  0.2.0 → 0.3.0
up/minor:
	@ruby -i -e ' \
	  src = ARGF.read; \
	  src.sub!(/spec\.version\s*=\s*"(\d+)\.(\d+)\.(\d+)"/) { \
	    "spec.version       = \"#{$$1}.#{$$2.to_i + 1}.0\"" \
	  }; \
	  print src \
	' active_harness.gemspec
	@echo "version → $$(ruby -e "load 'active_harness.gemspec'; puts Gem::Specification.load('active_harness.gemspec').version")"
	make release

# Bump major version:  0.2.0 → 1.0.0
up/major:
	@ruby -i -e ' \
	  src = ARGF.read; \
	  src.sub!(/spec\.version\s*=\s*"(\d+)\.(\d+)\.(\d+)"/) { \
	    "spec.version       = \"#{$$1.to_i + 1}.0.0\"" \
	  }; \
	  print src \
	' active_harness.gemspec
	@echo "version → $$(ruby -e "load 'active_harness.gemspec'; puts Gem::Specification.load('active_harness.gemspec').version")"
	make release
