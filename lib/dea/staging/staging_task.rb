require "tempfile"
require "tmpdir"
require "yaml"
require "shellwords"

require "dea/utils/download"
require "dea/utils/upload"
require "dea/promise"
require "dea/task"
require "dea/env"
require "dea/staging/admin_buildpack_downloader"
require "dea/staging/staging_task_workspace"
require "dea/staging/staging_message"

module Dea
  class StagingTask < Task
    class StagingError < StandardError
      def initialize(msg)
        super("Error staging: #{msg}")
      end
    end

    class StagingTaskStoppedError < StagingError
      def initialize
        super("task stopped")
      end
    end

    attr_reader :bootstrap, :dir_server, :staging_message, :task_id, :droplet_sha1

    def initialize(bootstrap, dir_server, staging_message, buildpacks_in_use, custom_logger=nil)
      super(bootstrap.config, custom_logger)

      @bootstrap = bootstrap
      @dir_server = dir_server
      @staging_message = staging_message
      @task_id = staging_message.task_id
      @buildpacks_in_use = buildpacks_in_use

      logger.user_data[:task_id] = task_id
    end

    def start
      staging_promise = Promise.new do |p|
        resolve_staging_setup
        resolve_staging
        p.deliver
      end

      Promise.resolve(staging_promise) do |error, _|
        begin
          if error
            logger.info "staging.task.failed",
              error: error, backtrace: error.backtrace
          else
            logger.info "staging.task.completed"
          end

          trigger_after_complete(error)

          unless error
            begin
              resolve_staging_upload
            rescue => e
              logger.info "staging.task.upload-failed",
                error: e,
                backtrace: e.backtrace

              error = e
            end
          end

          trigger_after_upload(error)

          raise(error) if error
        ensure
          promise_destroy.resolve
          FileUtils.rm_rf(workspace.workspace_dir)
        end
      end
    end

    def workspace
      @workspace ||= StagingTaskWorkspace.new(
        config["base_dir"],
        staging_message,
        @buildpacks_in_use
      )
    end

    def task_log
      File.read(workspace.staging_log_path) if File.exists?(workspace.staging_log_path)
    end

    def streaming_log_url
      @dir_server.staging_task_file_url_for(task_id, workspace.warden_staging_log)
    end

    def task_info
      File.exists?(workspace.staging_info_path) ? YAML.load_file(workspace.staging_info_path) : {}
    end

    def detected_buildpack
      task_info["detected_buildpack"]
    end

    def memory_limit_in_bytes
      (config.minimum_staging_memory_mb).to_i * 1024 * 1024
    end
    alias :used_memory_in_bytes :memory_limit_in_bytes

    def disk_limit_in_bytes
      (config.minimum_staging_disk_mb).to_i * 1024 * 1024
    end

    def stop(&callback)
      stopping_promise = Promise.new do |p|
        logger.info "staging.task.stopped"

        @after_complete_callback = nil # Unregister after complete callback
        promise_stop.resolve if container.handle
        p.deliver
      end

      Promise.resolve(stopping_promise) do |error, _|
        trigger_after_stop(StagingTaskStoppedError.new)
        callback.call(error) unless callback.nil?
      end
    end

    def after_setup_callback(&blk)
      @after_setup_callback = blk
    end

    def trigger_after_setup(error)
      @after_setup_callback.call(error) if @after_setup_callback
    end
    private :trigger_after_setup

    def after_complete_callback(&blk)
      @after_complete_callback = blk
    end

    def trigger_after_complete(error)
      @after_complete_callback.call(error) if @after_complete_callback
    end
    private :trigger_after_complete

    def after_upload_callback(&blk)
      @after_upload_callback = blk
    end

    def trigger_after_upload(error)
      @after_upload_callback.call(error) if @after_upload_callback
    end
    private :trigger_after_upload

    def after_stop_callback(&blk)
      @after_stop_callback = blk
    end

    def trigger_after_stop(error)
      @after_stop_callback.call(error) if @after_stop_callback
    end
    private :trigger_after_stop

    def prepare_workspace
      workspace.prepare
    end

    def promise_prepare_staging_log
      Promise.new do |p|
        script = "mkdir -p #{workspace.warden_staged_dir}/logs && touch #{workspace.warden_staging_log}"

        logger.info "staging.task.preparing-log", script: script

        container.run_script(:app, script)

        p.deliver
      end
    end

    def promise_app_dir
      Promise.new do |p|
        # Some buildpacks seem to make assumption that /app is a non-empty directory
        # See: https://github.com/heroku/heroku-buildpack-python/blob/master/bin/compile#L46
        # TODO possibly remove this if pull request is accepted
        script = "mkdir -p /app && touch /app/support_heroku_buildpacks && chown -R vcap:vcap /app"

        logger.info "staging.task.making-app-dir", script: script

        container.run_script(:app, script, true)

        p.deliver
      end
    end

    def promise_stage
      Promise.new do |p|
        env = Env.new(staging_message, self)

        script = [
          env.exported_environment_variables,
          config["dea_ruby"],
          run_plugin_path,
          workspace.plugin_config_path,
          ">> #{workspace.warden_staging_log} 2>&1"
        ].join(" ")

        logger.debug "staging.task.execute-staging", script: script

        Timeout.timeout(staging_timeout + staging_timeout_grace_period) do
          container.run_script(:app, script)
        end

        p.deliver
      end
    end

    def promise_task_log
      Promise.new do |p|
        copy_out_request(workspace.warden_staging_log, File.dirname(workspace.staging_log_path))
        logger.info "staging.task-log", log: task_log
        p.deliver
      end
    end

    def promise_staging_info
      Promise.new do |p|
        copy_out_request(workspace.warden_staging_info, File.dirname(workspace.staging_info_path))
        logger.info "staging.task-info", info: task_info
        p.deliver
      end
    end

    def promise_unpack_app
      Promise.new do |p|
        logger.info "staging.task.unpacking-app", destination: workspace.warden_unstaged_dir

        container.run_script(:app, <<-BASH)
          package_size=`du -h #{workspace.downloaded_app_package_path} | cut -f1`
          echo "-----> Downloaded app package ($package_size)" >> #{workspace.warden_staging_log}
          unzip -q #{workspace.downloaded_app_package_path} -d #{workspace.warden_unstaged_dir}
        BASH

        p.deliver
      end
    end

    def promise_pack_app
      Promise.new do |p|
        logger.info "staging.task.packing-droplet"

        container.run_script(:app, <<-BASH)
          cd #{workspace.warden_staged_dir} &&
          COPYFILE_DISABLE=true tar -czf #{workspace.warden_staged_droplet} .
        BASH
        p.deliver
      end
    end

    def promise_app_download
      Promise.new do |p|
        logger.info "staging.app-download.starting", uri: staging_message.download_uri

        download_destination = Tempfile.new("app-package-download.tgz")

        Download.new(staging_message.download_uri, download_destination, nil, logger).download! do |error|
          if error
            logger.debug "staging.app-download.failed",
              duration: p.elapsed_time,
              error: error,
              backtrace: error.backtrace

            p.fail(error)
          else
            File.rename(download_destination.path, workspace.downloaded_app_package_path)
            File.chmod(0744, workspace.downloaded_app_package_path)

            logger.debug "staging.app-download.completed",
              duration: p.elapsed_time,
              destination: workspace.downloaded_app_package_path

            p.deliver
          end
        end
      end
    end

    def promise_log_upload_started
      Promise.new do |p|
        container.run_script(:app, <<-BASH)
          droplet_size=`du -h #{workspace.warden_staged_droplet} | cut -f1`
          echo "-----> Uploading droplet ($droplet_size)" >> #{workspace.warden_staging_log}
        BASH
        p.deliver
      end
    end

    def promise_app_upload
      Promise.new do |p|
        logger.info "staging.droplet-upload.starting",
          source: workspace.staged_droplet_path,
          destination: staging_message.upload_uri

        Upload.new(workspace.staged_droplet_path, staging_message.upload_uri, logger).upload! do |error|
          if error
            logger.info "staging.task.droplet-upload-failed",
              duration: p.elapsed_time,
              destination: staging_message.upload_uri,
              error: error,
              backtrace: error.backtrace

            p.fail(error)
          else
            logger.info "staging.task.droplet-upload-completed",
              duration: p.elapsed_time,
              destination: staging_message.upload_uri

            p.deliver
          end
        end
      end
    end

    def promise_buildpack_cache_upload
      Promise.new do |p|
        logger.info "staging.buildpack-cache-upload.starting",
          source: workspace.staged_buildpack_cache_path,
          destination: staging_message.buildpack_cache_upload_uri

        Upload.new(workspace.staged_buildpack_cache_path, staging_message.buildpack_cache_upload_uri, logger).upload! do |error|
          if error
            logger.info "staging.task.buildpack-cache-upload-failed",
              duration: p.elapsed_time,
              destination: staging_message.buildpack_cache_upload_uri,
              error: error,
              backtrace: error.backtrace

            p.fail(error)
          else
            logger.info "staging.task.buildpack-cache-upload-completed",
              duration: p.elapsed_time,
              destination: staging_message.buildpack_cache_upload_uri

            p.deliver
          end
        end
      end
    end

    def promise_buildpack_cache_download
      Promise.new do |p|
        logger.info "staging.buildpack-cache-download.starting",
          uri: staging_message.buildpack_cache_download_uri

        download_destination = Tempfile.new("buildpack-cache", workspace.tmpdir)

        Download.new(staging_message.buildpack_cache_download_uri, download_destination, nil, logger).download! do |error|
          if error
            logger.debug "staging.buildpack-cache-download.failed",
              duration: p.elapsed_time,
              uri: staging_message.buildpack_cache_download_uri,
              error: error,
              backtrace: error.backtrace

          else
            File.rename(download_destination.path, workspace.downloaded_buildpack_cache_path)
            File.chmod(0744, workspace.downloaded_buildpack_cache_path)

            logger.debug "staging.buildpack-cache-download.completed",
              duration: p.elapsed_time,
              destination: workspace.downloaded_buildpack_cache_path
          end

          p.deliver
        end
      end
    end

    def promise_copy_out
      Promise.new do |p|
        logger.info "staging.droplet.copying-out",
          source: workspace.warden_staged_droplet,
          destination: workspace.staged_droplet_dir

        copy_out_request(workspace.warden_staged_droplet, workspace.staged_droplet_dir)

        p.deliver
      end
    end

    def promise_save_droplet
      Promise.new do |p|
        @droplet_sha1 = Digest::SHA1.file(workspace.staged_droplet_path).hexdigest
        bootstrap.droplet_registry[@droplet_sha1].local_copy(workspace.staged_droplet_path) do |error|
          if error
            logger.error "staging.droplet.copy-failed",
              error: error, backtrace: error.backtrace

            p.fail
          else
            p.deliver
          end
        end
      end
    end

    def promise_save_buildpack_cache
      Promise.new do |p|
        resolve_and_log(promise_pack_buildpack_cache, "staging.buildpack-cache.save") do |error, _|
          unless error
            begin
              promise_copy_out_buildpack_cache.resolve
              promise_buildpack_cache_upload.resolve
            rescue => e
              error = e
            end
          end

          if error
            p.fail(error)
          else
            p.deliver
          end
        end
      end
    end

    def promise_pack_buildpack_cache
      Promise.new do |p|
        # TODO: Ignore if buildpack cache is empty or does not exist
        container.run_script(:app, <<-BASH)
          mkdir -p #{workspace.warden_cache} &&
          cd #{workspace.warden_cache} &&
          COPYFILE_DISABLE=true tar -czf #{workspace.warden_staged_buildpack_cache} .
        BASH
        p.deliver
      end
    end

    def promise_unpack_buildpack_cache
      Promise.new do |p|
        if File.exists?(workspace.downloaded_buildpack_cache_path)
          logger.info "staging.buildpack-cache.unpack",
            destination: workspace.warden_cache

          container.run_script(:app, <<-BASH)
          package_size=`du -h #{workspace.downloaded_buildpack_cache_path} | cut -f1`
          echo "-----> Downloaded app buildpack cache ($package_size)" >> #{workspace.warden_staging_log}
          mkdir -p #{workspace.warden_cache}
          tar xfz #{workspace.downloaded_buildpack_cache_path} -C #{workspace.warden_cache}
          BASH
        end

        p.deliver
      end
    end

    def promise_copy_out_buildpack_cache
      Promise.new do |p|
        logger.info "staging.buildpack-cache.copying-out",
          source: workspace.warden_staged_buildpack_cache,
          destination: workspace.staged_droplet_path

        copy_out_request(workspace.warden_staged_buildpack_cache, workspace.staged_droplet_dir)

        p.deliver
      end
    end

    def path_in_container(path)
      File.join(container.path, "tmp", "rootfs", path.to_s) if container.path
    end

    def staging_config
      config["staging"]
    end

    def staging_timeout
      (staging_config["max_staging_duration"] || "900").to_f
    end

    def bind_mounts
      [workspace.workspace_dir, workspace.buildpack_dir, workspace.admin_buildpacks_dir].collect do |path|
        {'src_path' => path, 'dst_path' => path}
      end + config["bind_mounts"]
    end

    private

    def resolve_staging_setup
      workspace.prepare
      with_network = false
      container.create_container(bind_mounts,
        disk_limit_in_bytes,
        memory_limit_in_bytes,
        with_network)
      promises = [promise_app_download]
      promises << promise_buildpack_cache_download if staging_message.buildpack_cache_download_uri

      Promise.run_in_parallel(*promises)
      promise_update = Promise.new do |p|
        container.update_path_and_ip
        p.deliver
      end
      Promise.run_in_parallel(
        promise_prepare_staging_log,
        promise_app_dir,
        promise_update
      )

    rescue => e
      trigger_after_setup(e)
      raise
    else
      trigger_after_setup(nil)
    end

    def resolve_staging
      Promise.run_serially(
        promise_unpack_app,
        promise_unpack_buildpack_cache,
        promise_stage,
        promise_pack_app,
        promise_copy_out,
        promise_save_droplet,
        promise_log_upload_started,
        promise_staging_info
      )
    ensure
      promise_task_log.resolve
    end

    def resolve_staging_upload
      promise_app_upload.resolve
      promise_save_buildpack_cache.resolve
    end

    def run_plugin_path
      File.join(workspace.buildpack_dir, "bin/run")
    end

    def staging_timeout_grace_period
      60
    end
  end
end
