#
# Common code for AIX providers
#
# Author::    Hector Rivas Gandara <keymon@gmail.com>
#
#  
class Puppet::Provider::AixObject < Puppet::Provider
  desc "User management for AIX! Users are managed with mkuser, rmuser, chuser, lsuser"
  #class << self

  # Commands for users
  #commands :lsgroup   => "/usr/sbin/lsgroup"
  #commands :lsuser    => "/usr/sbin/lsuser"

  # Constants
  
  # Loadable AIX I/A module for users and groups. By default we manage compat.
  # TODO:: add a type parameter to change this
  attr_accessor :ia_module
   
  # AIX attributes to properties mapping.
  # Include here the valid attributes to be managed by this provider.
  # The hash should map the AIX attribute (command output) names to
  # puppet names.
  attr_accessor :attribute_mapping, :attribute_mapping_rev
  
  def attribute_mapping_rev
    if @attribute_mapping_rev 
      @attribute_mapping_rev 
    else
      @attribute_mapping_rev = attribute_mapping.invert 
    end
  end 

  #-----
  def lsusercmd(value=@resource[:name])
    [self.class.command(:list),"-R", self.ia_module, value]
  end

  def lsgroupscmd(value=@resource[:name])
    [self.class.command(:lsgroup),"-R", self.ia_module, "-a", "id", value]
  end

  #-----
  def lscmd(value=@resource[:name])
    raise Puppet::Error, "Method not defined #{@resource.class.name} #{@resource.name}: #{detail}"
  end

  def addcmd(extra_attrs = [])
    raise Puppet::Error, "Method not defined #{@resource.class.name} #{@resource.name}: #{detail}"
  end

  def modifycmd(attributes_hash)
    raise Puppet::Error, "Method not defined #{@resource.class.name} #{@resource.name}: #{detail}"
  end

  def deletecmd
    raise Puppet::Error, "Method not defined #{@resource.class.name} #{@resource.name}: #{detail}"
  end


  #-----
  # Parse AIX command attributes (string) and return provider hash
  # If a mapping is provided, the keys are translated as defined in the
  # mapping hash. Only values included in mapping will be added
  # NOTE: it will ignore the first item
  def attr2hash(str, mapping=nil)
    properties = {}
    attrs = []
    if !str or (attrs = str.split()[0..-1]).empty?
      return nil
    end 

    attrs.each { |i|
      if i.include? "=" # Ignore if it does not include '='
        (key, val) = i.split('=')
        # Check the key
        if !key or key.empty?
          info "Empty key in string 'i'?"
          continue
        end
        
        # Change the key if needed
        if mapping
          if mapping.include? key.to_sym
            properties[mapping[key.to_sym]] = val
          end
        else
          properties[key.to_sym] = val
        end
      end
    }
    properties.empty? ? nil : properties
  end

  # Convert the provider properties to AIX command attributes (string)
  def hash2attr(hash, mapping=nil)
    return "" unless hash 
    attr_list = []
    hash.each {|i|
      if mapping
        if mapping.include? i[0]
          # Convert arrays to list separated by commas
          if i[1].is_a? Array
            value = i[1].join(",")
          else
            value = i[1].to_s 
          end
          if ! value.include? " " 
            attr_list << (mapping[i[0]].to_s + "=" + value )
          else 
            attr_list << ('"' + mapping[i[0]].to_s + "=" + value + '"')
          end
        end
      else
        attr_list << (i[0].to_s + "='" + i[1] + "'")
      end
    }
    attr_list
  end

  # Private
  # Retrieve what we can about our object
  def getinfo(refresh = false)
    if @objectinfo.nil? or refresh == true
        # Execute lsuser, split all attributes and add them to a dict.
      begin
        attrs = execute(self.lscmd).split("\n")[0]
        Puppet.debug "aix.getinfo(): #{attrs} " 
        @objectinfo = attr2hash(attrs, attribute_mapping)
      rescue Puppet::ExecutionFailure => detail
        # Print error if needed
        Puppet.debug "aix.getinfo(): Could not find #{@resource.class.name} #{@resource.name}: #{detail}" \
          unless detail.to_s.include? "User \"#{@resource.name}\" does not exist."
      end
    end
    @objectinfo
  end

  # Private
  # Get the groupname from its id
  def groupname_by_id(gid)
    groupname=nil
    execute(lsgroupscmd("ALL")).each { |entry|
      attrs = attr2hash(entry)
      if attrs and attrs.include? :id and gid == attrs[:id].to_i
        groupname = entry.split(" ")[0]
      end
    }
    groupname
  end

  # Private
  # Get the groupname from its id
  def groupid_by_name(groupname)
    attrs = attr2hash(execute(lsgroupscmd(groupname)).split("\n")[0])
    attrs ? attrs[:id].to_i : nil
  end

  # Check that a group exists and is valid
  def verify_group(value)
    if value.is_a? Integer or value.is_a? Fixnum  
      groupname = groupname_by_id(value)
      raise ArgumentError, "AIX group must be a valid existing group" unless groupname
    else 
      raise ArgumentError, "AIX group must be a valid existing group" unless groupid_by_name(value)
      groupname = value
    end
    groupname
  end
  
  #-------------
  # Provider API
  # ------------
 
  # Clear out the cached values.
  def flush
    @property_hash.clear if @property_hash
    @object_info.clear if @object_info
  end

  # Check that the user exists
  def exists?
    !!getinfo(true) # !! => converts to bool
  end

  #- **ensure**
  #    The basic state that the object should be in.  Valid values are
  #    `present`, `absent`, `role`.
  # From ensurable: exists?, create, delete
  def ensure
    if exists?
      :present
    else
      :absent
    end
  end

  # Return all existing instances  
  # The method for returning a list of provider instances.  Note that it returns
  # providers, preferably with values already filled in, not resources.
  def self.instances
    objects = []
    execute(lscmd("ALL")).each { |entry|
      objects << new(:name => entry.split(" ")[0], :ensure => :present)
    }
    objects
  end

  def create
    if exists?
      info "already exists"
      # The object already exists
      return nil
    end

    begin
      execute(self.addcmd)
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not create #{@resource.class.name} #{@resource.name}: #{detail}"
    end
    # Reset the password if needed
    self.password = @resource[:password] if @resource[:password]
  end 

  def delete
    unless exists?
      info "already absent"
      # the object already doesn't exist
      return nil
    end

    begin
      execute(self.deletecmd)
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not delete #{@resource.class.name} #{@resource.name}: #{detail}"
    end
  end

  #--------------------------------
  # When the object is initialized, 
  # create getter/setter methods for each property our resource type supports.
  # If setter or getter already defined it will not be overwritten
  def self.mk_resource_methods
    [resource_type.validproperties, resource_type.parameters].flatten.each do |prop|
      Puppet.debug("Calling mk_resource_methods: #{prop.to_s} #{self.class.to_s}")
      next if prop == :ensure
      define_method(prop) { get(prop) || :absent} unless public_method_defined?(prop)
      define_method(prop.to_s + "=") { |*vals| set(prop, *vals) } unless public_method_defined?(prop.to_s + "=")
    end
  end
  #mk_resource_methods

  # Define the needed getters and setters as soon as we know the resource type
  def self.resource_type=(resource_type)
    super
    mk_resource_methods
  end
  
  # Retrieve a specific value by name.
  def get(param)
    (hash = getinfo(false)) ? hash[param] : nil
  end

  # Set a property.
  def set(param, value)
    @property_hash[symbolize(param)] = value
    # If value does not change, do not update.    
    if value == getinfo()[symbolize(param)]
      return
    end
    
    #self.class.validate(param, value)
    cmd = modifycmd({param => value})
    begin
      execute(cmd)
    rescue Puppet::ExecutionFailure  => detail
      raise Puppet::Error, "Could not set #{param} on #{@resource.class.name}[#{@resource.name}]: #{detail}"
    end
    
    # Refresh de info.  
    hash = getinfo(true)
   
  end

  def initialize(resource)
    super
    @objectinfo = nil
    self.ia_module = "compat"
  end  

end
#end
