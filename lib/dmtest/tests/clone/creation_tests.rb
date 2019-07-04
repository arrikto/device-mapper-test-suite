require 'dmtest/tvm'
require 'dmtest/utils'
require 'dmtest/disk-units'
require 'dmtest/test-utils'
require 'dmtest/thinp-test'
require 'dmtest/clone_stack'

#----------------------------------------------------------------

class CreationTests < ThinpTestCase
  include Utils
  include DiskUnits
  include TinyVolumeManager
  extend TestUtils

  define_test :bring_up_clone_target do
    s = CloneStack.new(@dm, @metadata_dev, @data_dev)
    s.activate {}
  end

  define_test :huge_region_size do
    region_size = 524288

    s = CloneStack.new(@dm, @metadata_dev, @data_dev, :size => region_size,
                       :region_size => region_size)

    s.activate do
      dt_device(s.clone)
    end
  end

  define_test :non_power_of_2_region_size_fails do
    s = CloneStack.new(@dm, @metadata_dev, @data_dev,
                       :region_size => k(4) + 57)

    assert_raise(ExitError) do
      s.activate {}
    end
  end

  define_test :too_small_region_size_fails do
    region_size = 4 # 2 KiB

    s = CloneStack.new(@dm, @metadata_dev, @data_dev,
                       :region_size => region_size)

    assert_raise(ExitError) do
      s.activate {}
    end
  end

  define_test :too_large_region_size_fails do
    region_size = 2 ** 22 # 2 GiB
    size = region_size
    metadata_size = meg(4)

    s = CloneStack.new(@dm, @metadata_dev, @data_dev, :size => size,
                       :metadata_size => metadata_size,
                       :region_size => region_size)

    assert_raise(ExitError) do
      s.activate {}
    end
  end

  define_test :largest_region_size_succeeds do
    region_size = 2 ** 21 # 1 GiB
    size = region_size
    metadata_size = meg(4)

    s = CloneStack.new(@dm, @metadata_dev, @data_dev, :size => size,
                       :metadata_size => metadata_size,
                       :region_size => region_size)
    s.activate {}
  end

  define_test :too_small_metadata_dev_fails do
    tvm = VM.new
    tvm.add_allocation_volume(@data_dev)

    md_size = 32 # 16KiB, way too small
    size = 2097152 # 1 GiB

    tvm.add_volume(linear_vol('md', md_size))
    tvm.add_volume(linear_vol('dest', size))
    tvm.add_volume(linear_vol('source', size))

    with_devs(tvm.table('md'), tvm.table('dest'),
              tvm.table('source')) do |md, dest, source|
      wipe_device(md)
      assert_raise(ExitError) do
        with_dev(Table.new(CloneTarget.new(size, md, dest, source, k(4)))) {}
      end
    end
  end

  define_test :opening_with_different_region_size_fails do
    tvm = VM.new
    tvm.add_allocation_volume(@data_dev)

    md_size = meg(4)
    size = meg(512)

    tvm.add_volume(linear_vol('md', md_size))
    tvm.add_volume(linear_vol('dest', size))
    tvm.add_volume(linear_vol('source', size))

    with_devs(tvm.table('md'), tvm.table('dest'),
              tvm.table('source')) do |md, dest, source|
      wipe_device(md)
      with_dev(Table.new(CloneTarget.new(size, md, dest, source, k(64)))) {}

      # Open with smaller region size
      assert_raise(ExitError) do
        with_dev(Table.new(CloneTarget.new(size, md, dest, source, k(4)))) {}
      end

      # Open with larger region size
      assert_raise(ExitError) do
        with_dev(Table.new(CloneTarget.new(size, md, dest, source, k(128)))) {}
      end
    end
  end

  define_test :opening_with_different_target_size_fails do
    tvm = VM.new
    tvm.add_allocation_volume(@data_dev)

    md_size = meg(4)
    size = meg(512)

    tvm.add_volume(linear_vol('md', md_size))
    tvm.add_volume(linear_vol('dest', size * 2))
    tvm.add_volume(linear_vol('source', size * 2))

    with_devs(tvm.table('md'), tvm.table('dest'),
              tvm.table('source')) do |md, dest, source|
      wipe_device(md)
      with_dev(Table.new(CloneTarget.new(size, md, dest, source, k(4)))) {}

      # Open with smaller target size
      assert_raise(ExitError) do
        with_dev(Table.new(CloneTarget.new(size - 1, md, dest, source, k(4)))) {}
      end

      # Open with larger target size
      assert_raise(ExitError) do
        with_dev(Table.new(CloneTarget.new(size + 1, md, dest, source, k(4)))) {}
      end
    end
  end

  define_test :data_devices_smaller_than_target_fails do
    tvm = VM.new
    tvm.add_allocation_volume(@data_dev)

    md_size = meg(4)
    size = meg(512)

    tvm.add_volume(linear_vol('md', md_size))
    tvm.add_volume(linear_vol('data', size))
    tvm.add_volume(linear_vol('small_data', size - 1))

    with_devs(tvm.table('md'), tvm.table('data'),
              tvm.table('small_data')) do |md, data, small_data|
      # Destination device smaller than target size
      wipe_device(md)

      assert_raise(ExitError) do
        with_dev(Table.new(CloneTarget.new(size, md, small_data, data, k(4)))) {}
      end

      # Source device smaller than target size
      wipe_device(md)

      assert_raise(ExitError) do
        with_dev(Table.new(CloneTarget.new(size, md, data, small_data, k(4)))) {}
      end
    end
  end
end

#----------------------------------------------------------------
