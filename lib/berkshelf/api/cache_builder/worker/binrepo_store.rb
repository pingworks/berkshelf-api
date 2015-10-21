require 'rubygems/package'
require 'zlib'
TAR_LONGLINK = '././@LongLink'

module Berkshelf::API
  class CacheBuilder
    module Worker
      class BinrepoStore < Worker::Base
        worker_type "binrepo_store"

        include Logging

        # @return [String]
        attr_reader :repo_base_url

        # @return [String]
        attr_reader :path

        # @return [String]
        attr_reader :import


        # @option options [String] :path
        #   the directory to search for local cookbooks
        def initialize(options = {})
          @repo_base_url = options[:repo_base_url]
          @path = Pathname(options[:path])
          @import = Pathname(options[:import])
          super(options)
        end

        # @return [String]
        def to_s
          friendly_name(path)
        end

        # @return [Array<RemoteCookbook>]
        #  The list of cookbooks this builder can find
        def cookbooks
          import_cookbooks
          [].tap do |cookbook_versions|
            @path.each_child do |cb_dir|
              log.info "Reading cookbook dir #{cb_dir}"
              cb_name = File.basename(cb_dir)
              Pathname(cb_dir).each_child do |cb_version_dir|
                cb_version = File.basename(cb_version_dir)
                if File.exist?("#{cb_version_dir}/#{cb_name}_#{cb_version}.tar.gz")
                  log.info "Found version #{cb_version} of cookbook #{cb_name}."
                  log.info "Registering released cookbook #{cb_name}_#{cb_version}.tar.gz..."
                  cookbook_versions << RemoteCookbook.new(cb_name, cb_version,
                                                          'uri', "#{@repo_base_url}/cookbooks/#{cb_name}/#{cb_version}/#{cb_name}_#{cb_version}.tar.gz", priority, {'repo_path' => "#{cb_version_dir}", 'package' => "#{cb_name}_#{cb_version}.tar.gz"})
                else
                  log.info "Cannot register cookbook #{cb_name}_#{cb_version}.tar.gz yet (bundle not fully unpacked yet)..."
                end
              end
            end
          end
        end

        # @param [RemoteCookbook] remote
        #
        # @return [Ridley::Chef::Cookbook::Metadata]
        def metadata(remote)
          log.info "Loading metadata from cookbook #{remote.name} (#{remote.version})..."
          unless Dir.exist?("#{remote.info['repo_path']}/#{remote.name}")
            log.info "Unpacking Cookbook #{remote.info['repo_path']}/#{remote.info['package']} ..."
            unpack_tar("#{remote.info['repo_path']}/#{remote.info['package']}", remote.info['repo_path'])
          end
          load_metadata("#{remote.info['repo_path']}/#{remote.name}")
        end

        private

        # imports uploaded cookbook bundles (only if version does not exist, no overwrite possible)
        # into binrepo folder structure
        def import_cookbooks
          @import.each_child do |cb_bundle|

            cb_full_tar = File.basename(cb_bundle)

            begin
              cb_version = extract_version(cb_full_tar)
              cb_name = extract_name(cb_full_tar)
              cb_single_tar = "#{cb_name}_#{cb_version}.tar.gz"
              cb_dir = "#{@path}/#{cb_name}/#{cb_version}"

              log.info "Found cookbook bundle #{File.basename(cb_bundle)} in import dir (name: #{cb_name} version: #{cb_version})."

              if !File.exist?("#{cb_dir}/#{cb_full_tar}") || !File.exist?("#{cb_dir}/#{cb_single_tar}")
                log.info "Importing cookbook bundle #{cb_full_tar}..."

                FileUtils.mkdir_p cb_dir unless Dir.exist?(cb_dir)

                FileUtils.cp(cb_bundle, cb_dir)

                unpack_single_cbs(cb_dir, cb_full_tar)

              else
                log.warn "Cookbook #{cb_name}@#{cb_version} already exists! WILL NOT OVERWRITE!"
                log.warn "Removing already imported cookbook from import dir..."
              end

              FileUtils.rm(cb_bundle)

            rescue => ex
              log.error "Failed to import cookbook pkg #{cb_full_tar}: #{ex.message}"
              log.info "Leaving cookbook pkg #{cb_full_tar} untouched."
            end
          end
        end

        # unpack and import single cookbooks from bundle
        # @param [String] bundle tar archive
        #
        def unpack_single_cbs(cb_dir, cb_full_tar)

          Dir.mktmpdir('unpack_', cb_dir) do |unpack_dir|

            unpack_tar("#{cb_dir}/#{cb_full_tar}", unpack_dir)

            Pathname("#{unpack_dir}/cookbooks/").each_child do |cb|
              cb_dir = File.basename(cb)
              metadata = load_metadata(cb)

              cb_single_tar = "#{metadata.name}_#{metadata.version}.tar.gz"
              cb_single_dir = "#{@path}/#{metadata.name}/#{metadata.version}"

              FileUtils.mkdir_p cb_single_dir unless Dir.exist?(cb_single_dir)
              system("cd #{unpack_dir}/cookbooks; tar cfz #{cb_single_dir}/#{cb_single_tar} #{cb_dir}") unless File.exist?("#{cb_single_dir}/#{cb_single_tar}")
              FileUtils.cp_r(cb, cb_single_dir) unless Dir.exist?("#{cb_single_dir}/#{metadata.name}")
            end
          end
        end

        # extract cookbook version from bundle tar-archive
        # @param [Sting] cb_bundle_filename
        #
        # @return [String]
        def extract_version(cb_bundle_filename)
          version = cb_bundle_filename.gsub(/^.*_(\d+\.\d+.\d+)-full\.tar\.gz$/, '\1')
          fail "Failed to extract cookbook version correctly! (#{version}, is this name following the naming convention?)" unless version.match(/^\d+\.\d+\.\d+$/)
          version
        end

        # extract cookbook name from bundle tar-archive
        # @param [Sting] cb_bundle_filename
        #
        # @return [String]
        def extract_name(cb_bundle_filename)
          name = cb_bundle_filename.gsub(/^(.*)_\d+\.\d+.\d+-full\.tar\.gz$/, '\1')
          fail "Failed to extract cookbook name correctly! (#{name}, is this name following the naming convention?)" unless name.match(/^[0-9A-Za-z_-]+$/)
          name
        end

        # Helper function for loading metadata from a particular directory
        #
        # @param [String] path
        #   path of directory to load from
        #
        # @return [Ridley::Chef::Cookbook::Metadata, nil]
        def load_metadata(path)
          cookbook = Ridley::Chef::Cookbook.from_path(path)
          cookbook.metadata
        rescue => ex
          log.error "Failed to load metadata from cookbook #{path}: #{ex.message}"
          log.info "Trying to get metadata info manually..."
          if File.exist?("#{path}/metadata.json")
            log.info "Reading #{path}/metadata.json ..."
            metadata_json = nil
            File.open("#{path}/metadata.json") do |file|
              log.info("ENV[LANG]=#{ENV['LANG']}")
              metadata_json = JSON.parse file.read
            end
            log.info "metadata_json: #{metadata_json}"

          end
        end


        def unpack_tar(tar_gz_archive, destination)
          Gem::Package::TarReader.new(Zlib::GzipReader.open tar_gz_archive) do |tar|
            dest = nil
            tar.each do |entry|
              if entry.full_name == TAR_LONGLINK
                dest = File.join destination, entry.read.strip
                next
              end
              dest ||= File.join destination, entry.full_name
              if entry.directory?
                FileUtils.rm_rf dest unless File.directory? dest
                FileUtils.mkdir_p dest, :mode => entry.header.mode, :verbose => false
              elsif entry.file?
                FileUtils.rm_rf dest unless File.file? dest
                File.open dest, "wb" do |f|
                  f.print entry.read
                end
                FileUtils.chmod entry.header.mode, dest, :verbose => false
              elsif entry.header.typeflag == '2' #Symlink!
                File.symlink entry.header.linkname, dest
              end
              dest = nil
            end
          end
        end
      end
    end
  end
end
