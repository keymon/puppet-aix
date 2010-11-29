#
# User Puppet provider for AIX. It uses standar commands to manage users:
#  mkuser, rmuser, lsuser, chuser
#
# Notes:
# - AIX users can have expiry date defined with minute granularity, but puppet does not allow it.
# - AIX maximum password age is in WEEKs, not days
# - I force the compat IA module. 
#
# See  http://projects.puppetlabs.com/projects/puppet/wiki/Development_Provider_Development
# for more information
#
# Author::    Hector Rivas Gandara <keymon@gmail.com>
#
# TODO::
#  - Add new AIX specific attributes, specilly registry and SYSTEM.
#  
require 'tempfile'
require 'date'

Puppet::Type.type(:user).provide :aix do
  desc "User management for AIX! Users are managed with mkuser, rmuser, chuser, lsuser"

  # This will the the default provider for this platform
  defaultfor :operatingsystem => :aix
  confine :operatingsystem => :aix

  # Commands that manage the element
  commands :add       => "/usr/bin/mkuser"
  commands :delete    => "/usr/sbin/rmuser"
  commands :modify    => "/usr/bin/chuser"
  commands :list      => "/usr/sbin/lsuser"
  commands :lsgroup   => "/usr/sbin/lsgroup"
  commands :chpasswd  => "/bin/chpasswd"

  # Provider features
  #has_features :manages_homedir, :allows_duplicates
  has_features :manages_homedir, :manages_passwords, :manages_expiry, :manages_password_age



  # Attribute verification (TODO)
  #verify :gid, "GID must be an string or int of a valid group" do |value|
  #  value.is_a? String || value.is_a? Integer
  #end
  #
  #verify :groups, "Groups must be comma-separated" do |value|
  #  value !~ /\s/
  #end


  # Constants
  
  # Loadable AIX I/A module. By default we manage compat.
  # TODO:: add a type parameter to change this
  @@IA_MODULE = "compat"
 
  # Default extra attributes to add when element is created
  # registry=compat SYSTEM=compat: Needed if you are using LDAP by default.
  @@DEFAULT_EXTRA_ATTRS = [ "registry=compat", " SYSTEM=compat" ]

  # AIX attributes to properties mapping.
  # Include here the valid attributes to be managed by this provider.
  # The hash should map the AIX attribute (command output) names to
  # puppet names.
  @@attribute_mapping = {
    #:name => :name,
    :pgrp => :gid,
    :id => :uid,
    :groups => :groups,
    :home => :home,
    :shell => :shell,
    :expires => :expiry,
    :maxage => :password_max_age,
    :minage => :password_min_age,
    :password => :password,
    #:comment => :comment,
    #:allowdupe => :allowdupe,
    #:auth_membership => :auth_membership,
    #:auths => :auths,
    #:ensure => :ensure,
    #:key_membership => :key_membership,
    #:keys => :keys,
    #:managehome => :managehome,
    #:membership => :membership,
    #:profile_membership => :profile_membership,
    #:profiles => :profiles,
    #:project => :project,
    #:role_membership => :role_membership,
    #:roles => :roles,
  }
  
  @@attribute_mapping_rev = @@attribute_mapping.invert

  #-----
  def lsusercmd(value=@resource[:name])
    [self.class.command(:list),"-R", @@IA_MODULE , value]
  end

  def lsgroupscmd(value)
    [self.class.command(:lsgroup),"-R", @@IA_MODULE , "-a", "id", value]
  end

  # Here we use the @resource.to_hash to get the list of provided parameters
  # Puppet does not call to self.<parameter>= method if it does not exists.
  #
  # It gets an extra list of arguments to add to the user.
  def addcmd(extra_attrs = [])
    [self.class.command(:add),"-R", @@IA_MODULE  ]+
      hash2attr(@resource.to_hash, @@attribute_mapping_rev) +
      extra_attrs + [@resource[:name]]
  end

  def modifycmd(attributes_hash)
    [self.class.command(:modify),"-R", @@IA_MODULE ]+
      hash2attr(@property_hash, @@attribute_mapping_rev) + [@resource[:name]]
  end

  def deletecmd
    [self.class.command(:delete),"-R", @@IA_MODULE, @resource[:name]]
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
        attrs = execute(self.lsusercmd).split("\n")[0]
        @objectinfo = attr2hash(attrs, @@attribute_mapping)
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
  def instances
    objects = []
    execute(lsusercmd("ALL")).each { |entry|
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
      next if prop == :ensure
      define_method(prop) { get(prop) || :absent} unless public_method_defined?(prop)
      define_method(prop.to_s + "=") { |*vals| set(prop, *vals) } unless public_method_defined?(prop.to_s + "=")
    end
  end
  mk_resource_methods
  
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

  #- **gid**
  #    The user's primary group.  Can be specified numerically or by name.
  def gid=(value)
    groupname = verify_group(value)
    set(:gid, groupname)
  end
  # FIXME: For puppet gid must be a number... puppet retrieves the gid number by itself :-/
  def gid
    hash = getinfo(false)
    if hash.include? :gid
      (hash[:gid].is_a? String) ? groupid_by_name(hash[:gid]) : hash[:gid]
    else
      :absent
    end
  end

  #- **password**
  #    The user's password, in whatever encrypted format the local machine
  #    requires. Be sure to enclose any value that includes a dollar sign ($)
  #    in single quotes (').  Requires features manages_passwords.
  #
  # Retrieve the password parsing directly the /etc/security/passwd
  def password
    password = :absent
    user = @resource[:name]
    f = File.open("/etc/security/passwd", 'r')
    # Skip to the user
    f.each { |l| break if l  =~ /^#{user}:\s*$/ }
    if ! f.eof?
      f.each { |l|
        # If there is a new user stanza, stop
        break if l  =~ /^\S*:\s*$/ 
        # If the password= entry is found, return it
        if l  =~ /^\s*password\s*=\s*(.*)$/
          password = $1; break;
        end
      }
    end
    f.close()
    return password
  end 

  def password=(value)
    user = @resource[:name]
    
    # Puppet execute does not support strings as input, only files.
    tmpfile = Tempfile.new('puppet_#{user}_pw')
    tmpfile << "#{user}:#{value}\n"
    tmpfile.close()

    # Options '-e', '-c', use encrypted password and clear flags
    # Must receibe "user:enc_password" as input
    # command, arguments = {:failonfail => true, :combine => true}
    cmd = [self.class.command(:chpasswd),"-R", @@IA_MODULE,
           '-e', '-c', user]
    begin
      execute(cmd, {:failonfail => true, :combine => true, :stdinfile => tmpfile.path })
    rescue Puppet::ExecutionFailure  => detail
      raise Puppet::Error, "Could not set #{param} on #{@resource.class.name}[#{@resource.name}]: #{detail}"
    ensure
      tmpfile.delete()
    end
  end 

  #- **expiry**
  #    The expiry date for this user. Must be provided in
  #    a zero padded YYYY-MM-DD format - e.g 2010-02-19.  Requires features
  #    manages_expiry.
  #
  # AIX supports hours, in this format: "2010-02-20 12:21"
  def expiry=(value)
    # For chuser the expires parameter is a 10-character string in the MMDDhhmmyy format
    # that is,"%m%d%H%M%y"
    newdate = '0'
    if value.is_a? String and value!="0000-00-00"
      d = DateTime.parse(value, "%Y-%m-%d %H:%M")
      newdate = d.strftime("%m%d%H%M%y")
    end
    set(:expiry, newdate)
  end
  
  def expiry
    hash = getinfo(false)
    if (hash[:expiry].is_a? String) and hash[:expiry] =~ /(..)(..)(..)(..)(..)/
      #d= DateTime.parse("20#{$5}-#{$1}-#{$2} #{$3}:#{$4}")
      #expiry_date = d.strftime("%Y-%m-%d %H:%M")
      #expiry_date = d.strftime("%Y-%m-%d")
      expiry_date = "20#{$5}-#{$1}-#{$2}"
    else
      expiry_date = :absent
    end
    expiry_date
  end
  
  
  #- **password_max_age**
  #    The maximum amount of time in days a password may be used before it must
  #    be changed  Requires features manages_password_age.
  #def password_max_age=(value)
  #end
  #
  #def password_max_age
  #end

  #- **password_min_age**
  #    The minimum amount of time in days a password must be used before it may
  #    be changed  Requires features manages_password_age.
  #def password_min_age=(value)
  #end
  #
  #def password_min_age
  #end

  # We get the getters/setters for each parameter from `pi user`.
  # Also from lib/puppet/type/user.rb, but is more difficult to read.

  #- **comment**
  #    A description of the user.  Generally is a user's full name.
  #def comment=(value)
  #end
  #
  #def comment
  #end
  # UNSUPPORTED
  

  #- **profile_membership**
  #    Whether specified roles should be treated as the only roles
  #    of which the user is a member or whether they should merely
  #    be treated as the minimum membership list.  Valid values are
  #    `inclusive`, `minimum`.
  # UNSUPPORTED
  #- **profiles**
  #    The profiles the user has.  Multiple profiles should be
  #    specified as an array.  Requires features manages_solaris_rbac.
  # UNSUPPORTED
  #- **project**
  #    The name of the project associated with a user  Requires features
  #    manages_solaris_rbac.
  # UNSUPPORTED
  #- **role_membership**
  #    Whether specified roles should be treated as the only roles
  #    of which the user is a member or whether they should merely
  #    be treated as the minimum membership list.  Valid values are
  #    `inclusive`, `minimum`.
  # UNSUPPORTED
  #- **roles**
  #    The roles the user has.  Multiple roles should be
  #    specified as an array.  Requires features manages_solaris_rbac.
  # UNSUPPORTED
  #- **key_membership**
  #    Whether specified key value pairs should be treated as the only
  #    attributes
  #    of the user or whether they should merely
  #    be treated as the minimum list.  Valid values are `inclusive`,
  #    `minimum`.
  # UNSUPPORTED
  
  #- **keys**
  #    Specify user attributes in an array of keyvalue pairs  Requires features
  #    manages_solaris_rbac.
  # UNSUPPORTED

  #- **allowdupe**
  #  Whether to allow duplicate UIDs.  Valid values are `true`, `false`.
  # UNSUPPORTED

  #- **auths**
  #    The auths the user has.  Multiple auths should be
  #    specified as an array.  Requires features manages_solaris_rbac.
  # UNSUPPORTED

  #- **auth_membership**
  #    Whether specified auths should be treated as the only auths
  #    of which the user is a member or whether they should merely
  #    be treated as the minimum membership list.  Valid values are
  #    `inclusive`, `minimum`.
  # UNSUPPORTED

  def initialize(resource)
    super
    @objectinfo = nil
  end  


end
