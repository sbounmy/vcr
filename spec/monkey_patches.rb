module MonkeyPatches
  extend self

  NET_HTTP_SINGLETON = class << Net::HTTP; self; end

  MONKEY_PATCHES = [
    [Net::BufferedIO,    :initialize],
    [Net::HTTP,          :request],
    [Net::HTTP,          :connect],
    [NET_HTTP_SINGLETON, :socket_type]
  ]

  def enable!
    MONKEY_PATCHES.each do |mp|
      realias mp.first, mp.last, :with_monkeypatches
    end
  end

  def disable!
    MONKEY_PATCHES.each do |mp|
      realias mp.first, mp.last, :without_monkeypatches
    end
  end

  def init
    # capture the monkey patched definitions so we can realias to them in the future
    MONKEY_PATCHES.each do |mp|
      capture_method_definition(mp.first, mp.last, false)
    end
  end

  private

  def capture_method_definition(klass, method, original)
    klass.class_eval do
      monkeypatch_methods = [
        :with_vcr,     :without_vcr,
        :with_fakeweb, :without_fakeweb,
        :with_webmock, :without_webmock
      ].select do |m|
        method_defined?(:"#{method}_#{m}")
      end

      if original
        if monkeypatch_methods.size > 0
          raise "The following monkeypatch methods have already been defined #{method}: #{monkey_patch_methods.inspect}"
        end
        alias_name = :"#{method}_without_monkeypatches"
      else
        if monkeypatch_methods.size == 0
          raise "No monkey patch methods have been defined for #{method}"
        end
        alias_name = :"#{method}_with_monkeypatches"
      end

      alias_method alias_name, method
    end
  end

  # capture the original method definitions before the monkey patches have been defined
  # so we can realias to the originals in the future
  MONKEY_PATCHES.each do |mp|
    capture_method_definition(mp.first, mp.last, true)
  end

  def realias(klass, method, alias_extension)
    klass.class_eval { alias_method method, :"#{method}_#{alias_extension}" }
  end
end
