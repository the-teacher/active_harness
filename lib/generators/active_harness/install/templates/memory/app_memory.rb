class AppMemory < ActiveHarness::Memory::JsonFile
  # Usage: AppMemory.new(file_name: "users/42")
  #
  # Wraps ActiveHarness::Memory::JsonFile with project defaults so callers
  # only need to pass a file_name. Slashes create subdirectories.
  def initialize(file_name:, **opts)
    super(
      file_name:    file_name,
      storage_path: Rails.root.join("storage", "ai", "memory").to_s,
      depth:        10,
      storage_size: 200,
      pretty:       Rails.env.development?,
      **opts
    )
  end
end
