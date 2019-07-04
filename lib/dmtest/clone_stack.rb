require 'dmtest/tvm'
require 'dmtest/utils'
require 'dmtest/disk-units'
require 'dmtest/ensure_elapsed'
require 'dmtest/device-mapper/table'
require 'dmtest/device-mapper/lexical_operators'

require 'dmtest/clone_status'

#----------------------------------------------------------------

class CloneStack
  include DM
  include Utils
  include DiskUnits
  include EnsureElapsed
  include TinyVolumeManager
  include DM::LexicalOperators

  attr_reader :clone, :md, :dest, :source, :opts

  # opts:
  #    :size (sectors),
  #    :metadata_size (sectors),
  #    :region_size (sectors),
  #    :format (bool),
  #    :discard_passdown (bool),
  #    :hydration (bool)
  #    :core_args (hash)
  def initialize(dm, fast_dev, slow_dev, opts = {})
    @dm = dm
    @fast_dev = fast_dev
    @slow_dev = slow_dev
    @opts = opts

    @fast_tvm = TinyVolumeManager::VM.new
    @fast_tvm.add_allocation_volume(@fast_dev)
    @fast_tvm.add_volume(linear_vol('md', metadata_size))
    @fast_tvm.add_volume(linear_vol('dest', size))

    @slow_tvm = TinyVolumeManager::VM.new
    @slow_tvm.add_allocation_volume(@slow_dev)
    @slow_tvm.add_volume(linear_vol('source', size))
  end

  def size
    @opts.fetch(:size, gig(1))
  end

  def metadata_size
    @opts.fetch(:metadata_size, meg(4))
  end

  def region_size
    @opts.fetch(:region_size, k(4))
  end

  def nr_regions
    div_up(size, region_size)
  end

  def clone_table
    hydration = @opts.fetch(:hydration, true)
    discard_passdown = @opts.fetch(:discard_passdown, true)
    core_args = @opts.fetch(:core_args, {})

    Table.new(CloneTarget.new(size, @md, @dest, @source, region_size, hydration,
                              discard_passdown, core_args))
  end

  def activate_support_devs(&block)
    with_devs(@fast_tvm.table('md'), @fast_tvm.table('dest'),
              @slow_tvm.table('source')) do |md, dest, source|
      @md = md
      @dest = dest
      @source = source

      wipe_device(md, 8) if @opts.fetch(:format, true)
      ensure_elapsed_time(1, self, &block)
    end
  end

  def activate_top_level(&block)
    with_dev(clone_table) do |clone|
      @clone = clone
      ensure_elapsed_time(1, self, &block)
    end
  end

  def activate(&block)
    with_devs(@fast_tvm.table('md'), @fast_tvm.table('dest'),
              @slow_tvm.table('source')) do |md, dest, source|
      @md = md
      @dest = dest
      @source = source

      wipe_device(md, 8) if @opts.fetch(:format, true)

      with_dev(clone_table) do |clone|
        @clone = clone
        ensure_elapsed_time(1, self, &block)
      end
    end
  end

  def enable_hydration
    @clone.message(0, "enable_hydration")
  end

  def disable_hydration
    @clone.message(0, "disable_hydration")
  end

  def set_hydration_threshold(nr_regions)
    @clone.message(0, "hydration_threshold #{nr_regions}")
  end

  def set_hydration_batch_size(nr_regions)
    @clone.message(0, "hydration_batch_size #{nr_regions}")
  end

  def wait_until_hydrated
    @clone.event_tracker.wait(@clone) do |clone|
      status = CloneStatus.new(clone)
      status.nr_hydrated_regions == status.nr_regions
    end
  end

  private
  def dm_interface
    @dm
  end
end

#----------------------------------------------------------------
