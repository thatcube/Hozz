# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tempfile"

# Ruby client for the same inherited-fd protocol used by shell build entrypoints.
module AppleBuildLease
  HELPER = File.expand_path("apple_build_lease.py", __dir__)
  PYTHON = "/usr/bin/python3"
  ENV_KEYS = %w[
    APPLE_BUILD_LEASE_PROTOCOL
    APPLE_BUILD_LEASE_MODE
    APPLE_BUILD_LEASE_OWNER
    APPLE_BUILD_LEASE_ID
    APPLE_BUILD_LEASE_TOKEN
    APPLE_BUILD_LEASE_PROOF_FD
    APPLE_BUILD_LEASE_LOCK_FD
  ].freeze
  ALL_ENV_KEYS = (
    ENV_KEYS + %w[
      APPLE_BUILD_LEASE_POLICY_LOCK_FD
      APPLE_BUILD_LEASE_ROLLOUT_FD
    ]
  ).freeze

  State = Struct.new(
    :owner,
    :lease_id,
    :token,
    :proof,
    :lock,
    :depth,
    :role,
    keyword_init: true
  )

  class << self
    def with_shared(owner)
      outer = @state.nil?
      acquire_shared(owner)
      completed = false
      result = yield
      completed = true
      result
    ensure
      if outer
        completed ? release : abandon
      elsif @state
        @state.depth -= 1
      end
    end

    def acquire_shared(owner)
      if @state
        @state.depth += 1
        return
      end

      inherited = ALL_ENV_KEYS.any? { |name| ENV.key?(name) }
      if inherited
        acquire_inherited_shared
        return
      end

      run_helper("prepare")
      root = run_helper("path", "root")
      lease_id = SecureRandom.uuid
      token = SecureRandom.uuid
      proof_path = File.join(root, "proof.#{lease_id}")
      proof = File.open(proof_path, File::RDWR | File::CREAT | File::EXCL, 0o600)
      File.unlink(proof_path)
      lock = File.open(File.join(root, "coordination.lock"), File::RDWR)
      proof.close_on_exec = false
      lock.close_on_exec = false

      run_helper(
        "acquire",
        "--mode", "shared",
        "--owner", owner,
        "--lease-id", lease_id,
        "--token", token,
        "--lock-fd", lock.fileno.to_s,
        "--proof-fd", proof.fileno.to_s,
        descriptors: descriptor_map(proof, lock)
      )
      install_environment(
        owner: owner,
        lease_id: lease_id,
        token: token,
        proof: proof,
        lock: lock
      )
      @state = State.new(
        owner: owner,
        lease_id: lease_id,
        token: token,
        proof: proof,
        lock: lock,
        depth: 1,
        role: "owner"
      )
    rescue StandardError
      proof&.close
      lock&.close
      clear_environment unless inherited
      raise
    end

    def release
      return unless @state

      state = @state
      if state.role == "owner"
        run_helper(
          "request-release",
          "--mode", "shared",
          "--owner", state.owner,
          "--lease-id", state.lease_id,
          "--token", state.token,
          "--lock-fd", state.lock.fileno.to_s,
          "--proof-fd", state.proof.fileno.to_s,
          descriptors: descriptor_map(state.proof, state.lock)
        )
        Process.spawn(
          PYTHON,
          HELPER,
          "finalize-release",
          "--mode", "shared",
          "--lease-id", state.lease_id,
          "--token", state.token,
          in: File::NULL,
          out: File::NULL,
          err: File::NULL,
          close_others: true
        ).then { |pid| Process.detach(pid) }
      end
    ensure
      close_state
    end

    def abandon
      close_state
    end

    private

    def acquire_inherited_shared
      unless ENV_KEYS.all? { |name| ENV.key?(name) && !ENV[name].empty? }
        raise "apple-build-interlock: incomplete inherited lease environment"
      end
      unless ENV["APPLE_BUILD_LEASE_PROTOCOL"] == "1" &&
             ENV["APPLE_BUILD_LEASE_MODE"] == "shared" &&
             !ENV.key?("APPLE_BUILD_LEASE_POLICY_LOCK_FD") &&
             !ENV.key?("APPLE_BUILD_LEASE_ROLLOUT_FD")
        raise "apple-build-interlock: inherited lease cannot satisfy shared mode"
      end

      proof_fd = parse_fd(ENV["APPLE_BUILD_LEASE_PROOF_FD"])
      lock_fd = parse_fd(ENV["APPLE_BUILD_LEASE_LOCK_FD"])
      proof = IO.for_fd(proof_fd, autoclose: false)
      lock = IO.for_fd(lock_fd, autoclose: false)
      role = run_helper(
        "validate",
        "--mode", "shared",
        "--owner", ENV["APPLE_BUILD_LEASE_OWNER"],
        "--lease-id", ENV["APPLE_BUILD_LEASE_ID"],
        "--token", ENV["APPLE_BUILD_LEASE_TOKEN"],
        "--lock-fd", lock_fd.to_s,
        "--proof-fd", proof_fd.to_s,
        descriptors: descriptor_map(proof, lock)
      )
      unless %w[owner inherited].include?(role)
        raise "apple-build-interlock: invalid inherited lease role"
      end

      @state = State.new(
        owner: ENV["APPLE_BUILD_LEASE_OWNER"],
        lease_id: ENV["APPLE_BUILD_LEASE_ID"],
        token: ENV["APPLE_BUILD_LEASE_TOKEN"],
        proof: proof,
        lock: lock,
        depth: 1,
        role: role
      )
    end

    def parse_fd(value)
      unless value.match?(/\A(?:[3-9]|[1-9][0-9]+)\z/)
        raise "apple-build-interlock: invalid inherited lease descriptor"
      end

      value.to_i
    end

    def descriptor_map(proof, lock)
      {
        proof.fileno => proof,
        lock.fileno => lock
      }
    end

    def install_environment(owner:, lease_id:, token:, proof:, lock:)
      ENV["APPLE_BUILD_LEASE_PROTOCOL"] = "1"
      ENV["APPLE_BUILD_LEASE_MODE"] = "shared"
      ENV["APPLE_BUILD_LEASE_OWNER"] = owner
      ENV["APPLE_BUILD_LEASE_ID"] = lease_id
      ENV["APPLE_BUILD_LEASE_TOKEN"] = token
      ENV["APPLE_BUILD_LEASE_PROOF_FD"] = proof.fileno.to_s
      ENV["APPLE_BUILD_LEASE_LOCK_FD"] = lock.fileno.to_s
    end

    def clear_environment
      ALL_ENV_KEYS.each { |name| ENV.delete(name) }
    end

    def close_state
      state = @state
      @state = nil
      return unless state

      state.proof.close unless state.proof.closed?
      state.lock.close unless state.lock.closed?
      clear_environment
    end

    def run_helper(*arguments, descriptors: {})
      log = Tempfile.new("apple-build-interlock")
      pid = Process.spawn(
        PYTHON,
        HELPER,
        *arguments,
        descriptors.merge(
          in: File::NULL,
          out: log,
          err: log,
          close_others: true
        )
      )
      _, status = Process.wait2(pid)
      log.flush
      log.rewind
      output = log.read.strip
      return output if status.success?

      raise "apple-build-interlock failed (#{status.exitstatus}): #{output}"
    ensure
      log&.close!
    end
  end
end
