require 'dmtest/fs'
require 'dmtest/git'
require 'dmtest/utils'
require 'dmtest/dataset'
require 'dmtest/disk-units'
require 'dmtest/thinp-test'
require 'dmtest/clone_stack'
require 'dmtest/clone_utils'
require 'dmtest/device-mapper/lexical_operators'

#----------------------------------------------------------------

class FSBench < ThinpTestCase
  include GitExtract
  include Utils
  include DiskUnits
  include CloneUtils
  include DM::LexicalOperators
  extend TestUtils

  FSTYPES = [:xfs, :ext4]

  def setup
    super

    @region_size = k(4)
    @size = gig(10)
    @metadata_size = meg(128)

    check_dev_size(@metadata_dev, @data_dev, @size, @metadata_size)
  end

  def bonnie(dir = '.')
    ProcessControl::run("bonnie++ -d #{dir} -r 0 -u root -s 2048")
  end

  def extract(dev)
      git_prepare(dev, :ext4)
      git_extract(dev, :ext4, TAGS[0..5])
  end

  def mkfs(dev, fs_type)
    puts "Formatting..."
    fs = FS::file_system(fs_type, dev)
    fs.format
  end

  def with_fs(dev, fs_type, opts={})
    fs = FS::file_system(fs_type, dev)

    if opts.fetch(:format, false)
      puts "Formatting..."
      fs.format
    end

    fs.with_mount('./bench_mnt') do
      Dir.chdir('./bench_mnt') do
        yield fs
      end
    end
  end

  def with_standard_linear(dev, &block)
    with_dev(Table.new(LinearTarget.new(@size, dev, 0)), &block)
  end

  def raw_test(dev, fs_type, desc, &block)
    with_fs(dev, fs_type, :format => true) do
      report_time(desc, &block)
    end
  end

  def clone_test(fs_type, &block)
    s = CloneStack.new(@dm, @metadata_dev, @data_dev,
                       :size => @size, :metadata_size => @metadata_size,
                       :region_size => @region_size, :hydration => false)

    s.activate_support_devs do
      mkfs(s.source, fs_type)

      # Populate FS
      ds = Dataset.read(LP('compile-bench-datasets/dataset-unpatched'))

      with_fs(s.source, fs_type, :format => false) do
        Dir.mkdir('linux')
        Dir.chdir('linux') do
          ds.apply
        end
      end

      s.activate_top_level do
        with_fs(s.clone, fs_type, :format => false) do |fs|
          fs.trim
          s.enable_hydration
          report_time("clone device test", &block)
        end
      end
    end
  end

  def bonnie_slow_device(fs_type)
    raw_test(@data_dev, fs_type, "slow device test") {bonnie}
  end

  define_tests_across(:bonnie_slow_device, FSTYPES)

  def bonnie_fast_device(fs_type)
    raw_test(@metadata_dev, fs_type, "fast device test") {bonnie}
  end

  define_tests_across(:bonnie_fast_device, FSTYPES)

  def bonnie_clone_device(fs_type)
    clone_test(fs_type) {bonnie}
  end

  define_tests_across(:bonnie_clone_device, FSTYPES)

  define_test :git_extract_slow_device do
    with_standard_linear(@data_dev) do |linear|
      extract(linear)
    end
  end

  define_test :git_extract_fast_device do
    with_standard_linear(@metadata_dev) do |linear|
      extract(linear)
    end
  end

  define_test :git_extract_clone_device do
    s = CloneStack.new(@dm, @metadata_dev, @data_dev,
                       :size => @size, :metadata_size => @metadata_size,
                       :region_size => @region_size, :hydration => false)

    s.activate_support_devs do
      git_prepare(s.source, :ext4)

      s.activate_top_level do
        with_fs(s.clone, :ext4, :format => false) do |fs|
          fs.trim
        end

        s.enable_hydration
        git_extract(s.clone, :ext4, TAGS[0..5])
      end
    end
  end
end

#----------------------------------------------------------------
