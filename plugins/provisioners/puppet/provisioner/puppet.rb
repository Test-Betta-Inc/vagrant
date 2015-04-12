require "digest/md5"

require "log4r"

module VagrantPlugins
  module Puppet
    module Provisioner
      class PuppetError < Vagrant::Errors::VagrantError
        error_namespace("vagrant.provisioners.puppet")
      end

      class Puppet < Vagrant.plugin("2", :provisioner)
        def initialize(machine, config)
          super

          @logger = Log4r::Logger.new("vagrant::provisioners::puppet")
        end

        def configure(root_config)
          # Calculate the paths we're going to use based on the environment
          root_path = @machine.env.root_path
          @expanded_module_paths   = @config.expanded_module_paths(root_path)

          # Setup the module paths
          @module_paths = []
          @expanded_module_paths.each_with_index do |path, _|
            key = Digest::MD5.hexdigest(path.to_s)
            @module_paths << [path, File.join(config.temp_dir, "modules-#{key}")]
          end

          folder_opts = {}
          folder_opts[:type] = @config.synced_folder_type if @config.synced_folder_type
          folder_opts[:owner] = "root" if !@config.synced_folder_type

          if @config.environment_path.is_a?(Array)
            # Share the environments directory with the guest
            if @config.environment_path[0].to_sym == :host
              root_config.vm.synced_folder(
                File.expand_path(@config.environment_path[1], root_path),
                environments_guest_path, folder_opts)
            end
          else
            # Non-Environment mode
            @manifest_file  = File.join(manifests_guest_path, @config.manifest_file)
            # Share the manifests directory with the guest
            if @config.manifests_path[0].to_sym == :host
              root_config.vm.synced_folder(
                File.expand_path(@config.manifests_path[1], root_path),
                manifests_guest_path, folder_opts)
            end
          end

          # Share the module paths
          @module_paths.each do |from, to|
            root_config.vm.synced_folder(from, to, folder_opts)
          end
        end

        # For convenience, add in any module_paths from the Puppet environment.cfg to the vagrant module_paths
        # This is needed because puppet apply does not read environment metadata (as of v3.6)
        def parse_environment_metadata
          environment_conf = File.join(environments_guest_path, @config.environment, "environment.conf")
          if @machine.communicate.test("test -e #{environment_conf}", sudo: true)
            conf = @machine.communicate.sudo("cat #{environment_conf}") do | type, data|
              if type == :stdout
                #modulepath = $basemodulepath:modules/private:modules/public
                puts "got line #{data}"
              end
            end
            puts "Found an environment cfg at: #{environment_conf} - #{conf}"
          else
            puts "env cfg not found, looked for #{environment_conf}"
          end
        end


        def provision
          # If the machine has a wait for reboot functionality, then
          # do that (primarily Windows)
          if @machine.guest.capability?(:wait_for_reboot)
            @machine.guest.capability(:wait_for_reboot)
          end

          # Check that the shared folders are properly shared
          check = []
          if @config.manifests_path.is_a?(Array) && @config.manifests_path[0] == :host
            check << manifests_guest_path
          end
          if @config.environment_path.is_a?(Array) && @config.environment_path[0] == :host
            check << environments_guest_path
          end
          @module_paths.each do |host_path, guest_path|
            check << guest_path
          end

          # Make sure the temporary directory is properly set up
          @machine.communicate.tap do |comm|
            comm.sudo("mkdir -p #{config.temp_dir}")
            comm.sudo("chmod 0777 #{config.temp_dir}")
          end

          verify_shared_folders(check)

          # Verify Puppet is installed and run it
          verify_binary(puppet_binary_path("puppet"))

          # Upload Hiera configuration if we have it
          @hiera_config_path = nil
          if config.hiera_config_path
            local_hiera_path   = File.expand_path(config.hiera_config_path,
              @machine.env.root_path)
            @hiera_config_path = File.join(config.temp_dir, "hiera.yaml")
            @machine.communicate.upload(local_hiera_path, @hiera_config_path)
          end

          parse_environment_metadata
          run_puppet_apply
        end

        def manifests_guest_path
          if config.manifests_path[0] == :host
            # The path is on the host, so point to where it is shared
            key = Digest::MD5.hexdigest(config.manifests_path[1])
            File.join(config.temp_dir, "manifests-#{key}")
          else
            # The path is on the VM, so just point directly to it
            config.manifests_path[1]
          end
        end

        def environments_guest_path
          if config.environment_path[0] == :host
            # The path is on the host, so point to where it is shared
            File.join(config.temp_dir, "environments")
          else
            # The path is on the VM, so just point directly to it
            config.environment_path[1]
          end
        end

        # Returns the path to the Puppet binary, taking into account the
        # `binary_path` configuration option.
        def puppet_binary_path(binary)
          return binary if !@config.binary_path
          return File.join(@config.binary_path, binary)
        end

        def verify_binary(binary)
          if !machine.communicate.test("sh -c 'command -v #{binary}'")
              @config.binary_path = "/opt/puppetlabs/bin"
              @machine.communicate.sudo(
                "test -x /opt/puppetlabs/bin/#{binary}",
                error_class: PuppetError,
                error_key: :not_detected,
                binary: binary)
          end
        end

        def run_puppet_apply
          default_module_path = "/etc/puppet/modules"
          if windows?
            default_module_path = "/ProgramData/PuppetLabs/puppet/etc/modules"
          end

          options = [config.options].flatten
          module_paths = @module_paths.map { |_, to| to }
          if !@module_paths.empty?
            # Append the default module path
            module_paths << default_module_path

            # Add the command line switch to add the module path
            module_path_sep = windows? ? ";" : ":"
            options << "--modulepath '#{module_paths.join(module_path_sep)}'"
          end

          if @hiera_config_path
            options << "--hiera_config=#{@hiera_config_path}"
          end

          if !@machine.env.ui.is_a?(Vagrant::UI::Colored)
            options << "--color=false"
          end

          options << "--detailed-exitcodes"
          if config.environment_path
            options << "#{environments_guest_path}/#{@config.environment}/manifests"
            options << "--environment #{@config.environment}"
          else
            options << "--manifestdir #{manifests_guest_path}"
            options << @manifest_file
          end
          options = options.join(" ")
          
          @machine.ui.info("Running ye puppet apply with options #{options}")

          # Build up the custom facts if we have any
          facter = ""
          if !config.facter.empty?
            facts = []
            config.facter.each do |key, value|
              facts << "FACTER_#{key}='#{value}'"
            end

            # If we're on Windows, we need to use the PowerShell style
            if windows?
              facts.map! { |v| "`$env:#{v};" }
            end

            facter = "#{facts.join(" ")} "
          end

          command = "#{facter} #{config.binary_path}/puppet apply #{options}"
          if config.working_directory
            if windows?
              command = "cd #{config.working_directory}; if (`$?) \{ #{command} \}"
            else
              command = "cd #{config.working_directory} && #{command}"
            end
          end

          if config.environment_path
            @machine.ui.info(I18n.t(
              "vagrant.provisioners.puppet.running_puppet_env",
              environment: config.environment))
          else
            @machine.ui.info(I18n.t(
              "vagrant.provisioners.puppet.running_puppet",
              manifest: config.manifest_file))
          end

          opts = {
            elevated: true,
            error_class: Vagrant::Errors::VagrantError,
            error_key: :ssh_bad_exit_status_muted,
            good_exit: [0,2],
          }
          @machine.communicate.sudo(command, opts) do |type, data|
            if !data.chomp.empty?
              @machine.ui.info(data.chomp)
            end
          end
        end

        def verify_shared_folders(folders)
          folders.each do |folder|
            @logger.debug("Checking for shared folder: #{folder}")
            if !@machine.communicate.test("test -d #{folder}", sudo: true)
              raise PuppetError, :missing_shared_folders
            end
          end
        end

        def windows?
          @machine.config.vm.communicator == :winrm
        end
      end
    end
  end
end
