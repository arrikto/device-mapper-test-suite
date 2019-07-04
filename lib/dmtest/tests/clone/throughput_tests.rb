require 'dmtest/fs'
require 'dmtest/utils'
require 'dmtest/dataset'
require 'dmtest/disk-units'
require 'dmtest/thinp-test'
require 'dmtest/clone_stack'
require 'dmtest/clone_utils'

#----------------------------------------------------------------

class ThroughputTests < ThinpTestCase
  include Utils
  include DiskUnits
  include CloneUtils
  extend TestUtils

  def setup
    super

    @size = gig(5)
    @max_size = gig(20)
    @metadata_size = meg(128)

    check_dev_size(@metadata_dev, @data_dev, @max_size, @metadata_size)
  end

  def mkfs(dev, fs_type)
    puts "Formatting..."
    fs = FS::file_system(fs_type, dev)
    fs.format
  end

  def with_fs(dev, fs_type)
    fs = FS::file_system(fs_type, dev)

    fs.with_mount('./bench_mnt') do
      Dir.chdir('./bench_mnt') do
        yield fs
      end
    end
  end

  def with_standard_linear(dev, size, &block)
    with_dev(Table.new(LinearTarget.new(size, dev, 0)), &block)
  end

  def across_various_io_sizes(&block)
    [k(64), k(128), k(256), k(512), k(1024)].each do |io_size|
      block.call(io_size)
    end
  end

  def across_various_region_sizes(&block)
    [k(4), k(64), k(128), k(256)].each do |region_size|
      block.call(region_size)
    end
  end

  def across_various_region_and_io_sizes(&block)
    across_various_region_sizes do |region_size|
      across_various_io_sizes do |io_size|
        block.call(region_size, io_size)
      end
    end
  end

  #------------------------
  # Device throughput tests
  #------------------------
  def throughput_clone_device(type, region_size, io_size)
    nr_regions = div_up(@size, region_size)
    size = nr_regions * region_size

    s = CloneStack.new(@dm, @metadata_dev, @data_dev, :size => size,
                       :metadata_size => @metadata_size,
                       :region_size => region_size, :hydration => false)
    s.activate do
          case type
          when :unhydrated
            # nothing to do
          when :hydrating
            s.enable_hydration
          when :hydrated
            s.clone.discard(0, dev_size(s.clone))
            s.enable_hydration
            s.wait_until_hydrated
          else
            raise "Unknown benchmark type `#{type}`"
          end

      report_time("volume size = #{size}, region_size = #{region_size}, io_size = #{io_size}", STDERR) do
        ProcessControl.run("dd if=/dev/zero of=#{s.clone} oflag=direct bs=#{io_size * 512} count=#{dev_size(s.clone) / io_size}")
      end
    end
  end

  def throughput_raw(dev, io_size)
    with_standard_linear(dev, @size) do |linear|
      report_time("volume size = #{@size}, io_size = #{io_size}", STDERR) do
        ProcessControl.run("dd if=/dev/zero of=#{linear} oflag=direct bs=#{io_size * 512} count=#{dev_size(linear) / io_size}")
      end
    end
  end

  define_test :unhydrated_clone_device_throughput do
    across_various_region_and_io_sizes do |region_size, io_size|
      throughput_clone_device(:unhydrated, region_size, io_size)
    end
  end

  define_test :hydrating_clone_device_throughput do
    across_various_region_and_io_sizes do |region_size, io_size|
      throughput_clone_device(:hydrating, region_size, io_size)
    end
  end

  define_test :hydrated_clone_device_throughput do
    across_various_region_and_io_sizes do |region_size, io_size|
      throughput_clone_device(:hydrated, region_size, io_size)
    end
  end

  define_test :fast_device_throughput do
    across_various_io_sizes do |io_size|
      throughput_raw(@metadata_dev, io_size)
    end
  end

  define_test :slow_device_throughput do
    across_various_io_sizes do |io_size|
      throughput_raw(@data_dev, io_size)
    end
  end

  #-------------
  # iozone tests
  #-------------
  def multithreaded_layout_reread(io_size, desc)
    # Use iozone to layout interleaved files on device and then re-read with dd
    # using DIO
    report_time("iozone init #{desc}", STDERR) do
      ProcessControl.run("iozone -i 0 -i 1 -w -+N -c -C -e -s 1g -r #{io_size / 2}k -t 8 -F ./1 ./2 ./3 ./4 ./5 ./6 ./7 ./8")
    end

    ProcessControl.run('echo 3 > /proc/sys/vm/drop_caches')

    report_time(" dd re-read #{desc}", STDERR) do
      ProcessControl.run("dd iflag=direct if=./1 of=/dev/null bs=#{io_size / 2}k")
    end
  end

  def throughput_multithreaded_layout_reread(type, fs_type, region_size, io_size)
    nr_regions = div_up(@max_size, region_size)
    size = nr_regions * region_size

    s = CloneStack.new(@dm, @metadata_dev, @data_dev, :size => size,
                       :metadata_size => @metadata_size,
                       :region_size => region_size, :hydration => false)

    s.activate_support_devs do
      mkfs(s.source, fs_type)

      # Populate FS
      ds = Dataset.read(LP('compile-bench-datasets/dataset-unpatched'))

      with_fs(s.source, fs_type) do
        Dir.mkdir('linux')
        Dir.chdir('linux') do
          ds.apply
        end
      end

      s.activate_top_level do
        with_fs(s.clone, fs_type) do |fs|
          fs.trim

          case type
          when :unhydrated
            # nothing to do
          when :hydrating
            s.enable_hydration
          when :hydrated
            s.enable_hydration
            s.wait_until_hydrated
          else
            raise "Unknown benchmark type `#{type}`"
          end

          multithreaded_layout_reread(io_size, "with region_size = #{region_size}, io_size = #{io_size}")
        end
      end
    end
  end

  def throughput_multithreaded_layout_reread_raw(dev, fs_type, io_size, desc)
    with_standard_linear(dev, @max_size) do |linear|
      mkfs(linear, fs_type)

      # Populate FS
      ds = Dataset.read(LP('compile-bench-datasets/dataset-unpatched'))

      with_fs(linear, fs_type) do
        Dir.mkdir('linux')
        Dir.chdir('linux') do
          ds.apply
        end

        multithreaded_layout_reread(io_size, desc)
      end
    end
  end

  define_test :throughput_multithreaded_layout_reread_clone_device_unhydrated do
    across_various_region_and_io_sizes do |region_size, io_size|
      throughput_multithreaded_layout_reread(:unhydrated, :ext4, region_size,
                                             io_size)
    end
  end

  define_test :throughput_multithreaded_layout_reread_clone_device_hydrating do
    across_various_region_and_io_sizes do |region_size, io_size|
      throughput_multithreaded_layout_reread(:hydrating, :ext4, region_size,
                                             io_size)
    end
  end

  define_test :throughput_multithreaded_layout_reread_clone_device_hydrated do
    across_various_region_and_io_sizes do |region_size, io_size|
      throughput_multithreaded_layout_reread(:hydrated, :ext4, region_size,
                                             io_size)
    end
  end

  define_test :throughput_multithreaded_layout_reread_fast_device do
    across_various_io_sizes do |io_size|
      throughput_multithreaded_layout_reread_raw(@metadata_dev, :ext4, io_size,
                                                 "fast device, io_size = #{io_size}")
    end
  end

  define_test :throughput_multithreaded_layout_reread_slow_device do
    across_various_io_sizes do |io_size|
      throughput_multithreaded_layout_reread_raw(@data_dev, :ext4, io_size,
                                                 "slow device, io_size = #{io_size}")
    end
  end

  #---------------------------
  # Hydration throughput tests
  #---------------------------
  def across_various_hydration_thresholds(region_size, &block)
    [meg(1), meg(2), meg(4), meg(8), meg(16)].each do |hydration_threshold_sectors|
      block.call(hydration_threshold_sectors / region_size)
    end
  end

  def across_various_hydration_batch_sizes(region_size, &block)
    blocks = [k(4), k(64), k(128), k(256), k(512), meg(1), meg(2), meg(4),
              meg(8), meg(16)]

    blocks.each do |hydration_batch_size_sectors|
      block.call(hydration_batch_size_sectors / region_size)
    end
  end

  def across_various_hydration_parameters(region_size, &block)
    across_various_hydration_thresholds(region_size) do |hydration_threshold|
      across_various_hydration_batch_sizes(region_size) do |hydration_batch_size|
        break if hydration_batch_size > hydration_threshold
        block.call(hydration_threshold, hydration_batch_size)
      end
    end
  end

  define_test :hydration_throughput do
    region_size = k(4)
    nr_regions = div_up(@size, region_size)
    size = nr_regions * region_size

    across_various_hydration_parameters(region_size) do |hydration_threshold, hydration_batch_size|
      s = CloneStack.new(@dm, @metadata_dev, @data_dev, :size => size,
                         :metadata_size => @metadata_size,
                         :region_size => region_size, :hydration => false)

      s.activate do
        s.set_hydration_threshold(hydration_threshold)
        s.set_hydration_batch_size(hydration_batch_size)

        s.enable_hydration
        report_time("volume size = #{size}, region_size = #{region_size}, hydration_threshold = #{hydration_threshold} (#{hydration_threshold * region_size}), hydration_batch_size = #{hydration_batch_size} (#{hydration_batch_size * region_size})", STDERR) do
          s.wait_until_hydrated
        end
      end
    end
  end
end
#----------------------------------------------------------------
