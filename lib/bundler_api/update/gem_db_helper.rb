require 'set'
require 'bundler_api'

class BundlerApi::GemDBHelper
  def initialize(db, gem_cache, mutex)
    @db        = db
    @gem_cache = gem_cache
    @mutex     = mutex
  end

  def exists?(payload)
    key = payload.full_name

    if @mutex
      @mutex.synchronize do
        return @gem_cache[key] if @gem_cache[key]
      end
    end

    dataset = @db[<<-SQL, payload.name, payload.version.version, payload.platform]
    SELECT rubygems.id AS rubygem_id, versions.id AS version_id
    FROM rubygems, versions
    WHERE rubygems.id = versions.rubygem_id
      AND rubygems.name = ?
      AND versions.number = ?
      AND versions.platform = ?
      AND versions.indexed = true
    SQL

    result = dataset.first

    if @mutex
      @mutex.synchronize do
        @gem_cache[key] = result if result
      end
    end

    result
  end

  def find_or_insert_rubygem(spec)
    insert     = nil
    rubygem_id = nil
    rubygem    = @db[:rubygems].filter(name: spec.name.to_s).select(:id).first

    if rubygem
      insert     = false
      rubygem_id = rubygem[:id]
    else
      insert     = true
      rubygem_id = @db[:rubygems].insert(name: spec.name)
    end

    @db[:checksums].filter(name: "names.list").update(md5: nil) if insert

    [insert, rubygem_id]
  end

  def update_info_checksum(version_id, info_checksum)
    @db[:versions].where(id: version_id).update(info_checksum: info_checksum)
  end

  def find_or_insert_version(spec, rubygem_id, platform = 'ruby', checksum = nil, indexed = nil)
    insert     = nil
    version_id = nil
    version    = @db[:versions].filter(
      rubygem_id: rubygem_id,
      number:     spec.version.version,
      platform:   platform,
    ).select(:id, :indexed).first

    if version
      insert     = false
      version_id = version[:id]
      @db[:versions].where(id: version_id).update(indexed: indexed) if !indexed.nil? && version[:indexed] != indexed
    else
      insert     = true
      indexed    = true if indexed.nil?

      spec_rubygems = spec.required_rubygems_version
      if spec_rubygems && !spec_rubygems.to_s.empty?
        rubygems_version = spec_rubygems.to_s
      end

      spec_ruby = spec.required_ruby_version
      if spec_ruby && !spec_ruby.to_s.empty?
        ruby_version = spec_ruby.to_s
      end

      version_id = @db[:versions].insert(
        number:      spec.version.version,
        rubygem_id:  rubygem_id,
        # rubygems.org actually uses the platform from the index and not from the spec
        platform:    platform,
        indexed:     indexed,
        prerelease:  !spec.version.prerelease?.nil?,
        full_name:   spec.full_name,
        rubygems_version: rubygems_version,
        required_ruby_version: ruby_version,
        checksum:    checksum,
        created_at:  Time.now
      )
    end

    if insert
      @db[:rubygems].filter(id: rubygem_id).update(deps_md5: nil)
      @db[:checksums].filter(name: "versions.list").update(md5: nil)
    end

    [insert, version_id]
  end

  def insert_dependencies(spec, version_id)
    deps_added = []

    spec.dependencies.each do |dep|
      rubygem_name = nil
      requirements = nil
      scope        = nil

      if dep.is_a?(Gem::Dependency)
        rubygem_name = dep.name.to_s
        requirements = dep.requirement.to_s
        scope        = dep.type.to_s
      else
        rubygem_name, requirements = dep
        # assume runtime for legacy deps
        scope                     = "runtime"
      end

      dep_rubygem = @db[:rubygems].filter(name: rubygem_name).select(:id).first
      if dep_rubygem
        dep = @db[:dependencies].filter(rubygem_id:   dep_rubygem[:id],
                                        version_id:   version_id).first
        if !dep || !matching_requirements?(requirements, dep[:requirements])
          deps_added << "#{requirements} #{rubygem_name}"
          @db[:dependencies].insert(
            requirements: requirements,
            rubygem_id:   dep_rubygem[:id],
            version_id:   version_id,
            scope:        scope
          )
        end
      end
    end

    deps_added
  end

  private
  def matching_requirements?(requirements1, requirements2)
    Set.new(requirements1.split(", ")) == Set.new(requirements2.split(", "))
  end
end
