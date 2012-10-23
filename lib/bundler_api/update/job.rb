require_relative 'payload'
require_relative '../metriks'

class Job
  attr_reader :payload
  @@gem_cache = {}

  def initialize(db, payload, mutex, gem_count)
    @db        = db
    @payload   = payload
    @mutex     = mutex
    @gem_count = gem_count
  end

  def run
    unless gem_exists?(@payload.name, @payload.version)
      @mutex.synchronize do
        @gem_count.increment
      end
      spec = download_spec(@payload.name, @payload.version, @payload.platform)
      @mutex.synchronize do
        insert_spec(spec)
      end
    end
  end

  private
  def gem_exists?(name, version)
    key = "#{name}-#{version}"

    @mutex.synchronize do
      return true if @@gem_cache[key]
    end

    timer   = Metriks.timer('job.gem_exists').time
    dataset = @db[<<-SQL, name, version.version]
    SELECT versions.id
    FROM rubygems, versions
    WHERE rubygems.id = versions.rubygem_id
      AND rubygems.name = ?
      AND versions.number = ?
    SQL

    result = dataset.count > 0

    @mutex.synchronize do
      @@gem_cache[key] = true if result
    end

    result
  ensure
    timer.stop if timer
  end

  def download_spec(name, version, platform)
    timer     = Metriks.timer('job.download_spec').time
    full_name = "#{name}-#{version}"
    full_name << "-#{platform}" if platform != 'ruby'
    url       = "http://rubygems.org/quick/Marshal.4.8/#{full_name}.gemspec.rz"
    count     = 0
    puts "Adding: #{full_name}"

    begin
      Marshal.load(Gem.inflate(open(url).string))
    rescue
      if count < 5
        retry
        count += 1
      else
        puts "Could not download #{url}"
      end
    end
  ensure
    timer.stop
  end

  def insert_spec(spec)
    raise "Failed to load spec" unless spec

    timer = Metriks.timer('job.insert_spec').time
    @db.transaction do
      rubygem    = @db[:rubygems].filter(name: spec.name.to_s).select(:id).first
      rubygem_id = nil
      if rubygem
        rubygem_id = rubygem[:id]
      else
        rubygem_id = @db[:rubygems].insert(
          name:       spec.name,
          created_at: Time.now,
          updated_at: Time.now,
          downloads:  0
        )
      end

      version_id = @db[:versions].insert(
        authors:     spec.authors,
        description: spec.description,
        number:      spec.version.version,
        rubygem_id:  rubygem_id,
        updated_at:  Time.now,
        summary:     spec.summary,
        platform:    spec.platform.to_s,
        created_at:  Time.now,
        indexed:     true,
        prerelease:  @payload.prerelease,
        latest:      true,
        full_name:   spec.full_name,
      )
      spec.dependencies.each do |dep|
        dep_rubygem = @db[:rubygems].filter(name: dep.name).select(:id).first
        if dep_rubygem
          @db[:dependencies].insert(
            requirements: dep.requirement.to_s,
            created_at:   Time.now,
            updated_at:   Time.now,
            rubygem_id:   dep_rubygem[:id],
            version_id:   version_id,
            scope:        dep.type.to_s,
          )
        end
      end
    end
  ensure
    timer.stop if timer
  end
end
