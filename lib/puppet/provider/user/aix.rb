# See  http://projects.puppetlabs.com/projects/puppet/wiki/Development_Provider_Development
# for more information

Puppet::Type.type(:user).provide :aixuseradd do
  
  desc "User management for AIX! Users are managed with mkuser, rmuser, chuser"

  defaultfor :operatingsystem => :aix
  confine :operatingsystem => :aix

  commands :add       => "/usr/bin/mkuser"
  commands :delete    => "/usr/sbin/rmuser"
  commands :modify    => "/usr/bin/chuser"
  commands :list      => "/usr/bin/lsuser"
  commands :lsgroup   => "/usr/bin/lsgroup"

  #verify :gid, "GID must be an string or int of a valid group" do |value|
  #  value.is_a? String || value.is_a? Integer
  #end
  #
  #verify :groups, "Groups must be comma-separated" do |value|
  #  value !~ /\s/
  #end

#def execute(commands)
#	commands_str = (commands.is_a? Array) ? commands.join(" ") : commands
#	output = IO.popen(commands_str)
#	output.readlines()
#end


  #has_features :manages_homedir, :allows_duplicates
  has_features :manages_homedir, :manages_password_age, :manages_expiry

  # Constants
  
  # Loadable AIX I/A module 
  ia_module = "files"

  # List of attributes to be ignored
  attributte_black_list = [ :time_last_login, :time_last_unsuccessful_login,
                              :tty_last_login, :tty_last_unsuccessful_login,
                            :host_last_login,:host_last_unsuccessful_login,
                            :unsuccessful_login_count ]
  
  # AIX attributes to properties mapping. Include here the valid attributes
  # to be managed by this provider
  attribute_mapping = {
    #:name => :name,
    :pgrp => :gid,
    :id => :uid,
    :groups => :groups,
    :home => :home,
    :shell => :shell,
    #:comment => :comment,
    #:allowdupe => :allowdupe,
    #:auth_membership => :auth_membership,
    #:auths => :auths,
    #:ensure => :ensure,
    #:expiry => :expiry,
    #:key_membership => :key_membership,
    #:keys => :keys,
    #:managehome => :managehome,
    #:membership => :membership,
    #:password => :password,
    #:password_max_age => :password_max_age,
    #:password_min_age => :password_min_age,
    #:profile_membership => :profile_membership,
    #:profiles => :profiles,
    #:project => :project,
    #:role_membership => :role_membership,
    #:roles => :roles,
  }

  attribute_mapping_rev = attribute_mapping.invert

  #-----
  def lsusercmd(value=@resource[:name])
    [self.class.command(:list),"-R ",ia_module, value]
  end

  def lsgroupscmd(value)
    [self.class.command(:lsgroup),"-R ",ia_module, "-a id", value]
  end

  def addcmd
    [self.class.command(:add),"-R ",ia_module,
      hash2attr(@property_hash, attribute_mapping_rev), @resource[:name]]
  end

  def modifycmd(attributes_hash)
    [self.class.command(:modify),"-R ",ia_module,
      hash2attr(attributes_hash, attribute_mapping_rev), @resource[:name]]
  end

  def deletecmd
    [self.class.command(:delete),"-R ",ia_module, @resource[:name]]
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
    attr_list = hash.map {|i|
      if mapping
        if mapping.include? i[0]
          mapping[i[0]].to_s + "='" + i[1] + "'" 
        end
      else
        i[0].to_s + "='" + i[1] + "'" 
      end
    }
    attr_list.join(" ")
  end

  # Private
  # Retrieve what we can about our object
  def getinfo(refresh = false)
    if @objectinfo.nil? or refresh == true
        # Execute lsuser, split all attributes and add them to a dict.
        Puppet.debug(getinfo() + ": " + self.lsusercmd)
        attrs = execute(self.lsusercmd)[0]
        @objectinfo = attr2hash(attrs, attribute_mapping)
    @objectinfo

  # Private
  # Get the groupname from its id
  def groupname_by_id(gid)
    groupname=nil
    Puppet.debug("groupname_by_id("+gid+"): " + lsgroupscmd("ALL"))
    execute(lsgroupscmd("ALL")).each { |entry|
      attrs = attr2hash(entry)
      if attrs and attrs.include? :id and gid == attrs[:id].to_i
        groupname = entry.split(" ")[0]
      end
    }
    Puppet.debug(groupname_by_id(gid) + "= " + groupname)
    groupname
  end

  # Private
  # Get the groupname from its id
  def groupid_by_name(groupname)
    Puppet.debug("groupid_by_name("+groupname+"): " + lsgroupscmd(groupname))
    attrs = attr2hash(execute(lsgroupscmd(groupname))[0])
    attrs ? attrs[:id] : nil
  end

  #-------------
  # Provider API
  # ------------
 
  # Clear out the cached values.
  def flush
    @property_hash.clear
    @object_info.clear
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
  def resource_type=(resource_type)
    super
    @resource_type.validproperties.each do |prop|
      next if prop == :ensure
      define_method(prop) { get(prop) || :absent} unless public_method_defined?(prop)
      define_method(prop.to_s + "=") { |*vals| set(prop, *vals) } unless public_method_defined?(prop.to_s + "=")
    end
  end

  # Retrieve a specific value by name.
  def get(param)
    (hash = getinfo(false)) ? hash[param] : nil
  end

  def set(param, value)
    @property_hash[symbolize(param)] = value
    
    #self.class.validate(param, value)
    cmd = modifycmd({param => value})
    begin
      execute(cmd)
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not set #{param} on #{@resource.class.name}[#{@resource.name}]: #{detail}"
    end
    
    # Refresh de info.  
    hash = getinfo(true)
   
  end

  #- **gid**
  #    The user's primary group.  Can be specified numerically or by name.
  def gid=(value)
    # It must be a string
    if value.is_a? Integer
      groupname = groupname_by_id(value)
      raise ArgumentError, "AIX group must be a valid existing group" unless groupname
    else 
      raise ArgumentError, "AIX group must be a valid existing group" unless groupid_by_name(value)
      groupname = value
    end
    set(:gid, groupname)
  end
  
  def initialize(resource)
    super
    @objectinfo = nil
  end  

  # We get the getters/setters for each parameter from `pi user`.
  # Also from lib/puppet/type/user.rb, but is more difficult to read.

  #- **comment**
  #    A description of the user.  Generally is a user's full name.
  #def comment=(value)
  #end
  #
  #def comment
  #end
  

  #- **expiry**
  #    The expiry date for this user. Must be provided in
  #    a zero padded YYYY-MM-DD format - e.g 2010-02-19.  Requires features
  #    manages_expiry.
  #
  #def expiry=(value)
  #end
  #
  #def expiry
  #end


  #- **membership**
  #    Whether specified groups should be treated as the only groups
  #    of which the user is a member or whether they should merely
  #    be treated as the minimum membership list.  Valid values are
  #    `inclusive`, `minimum`.
  #def membership=(value)
  #end
  #
  #def membership
  #end

  #- **groups**
  #    The groups of which the user is a member.  The primary
  #    group should not be listed.  Multiple groups should be
  #    specified as an array.
  #def groups=(value)
  #end
  #
  #def groups
  #end

  #- **managehome**
  #    Whether to manage the home directory when managing the user.  Valid
  #    values are `true`, `false`.
  #
  #def managehome=(value)
  #end
  #
  #def managehome
  #end

  #- **home**
  #    The home directory of the user.  The directory must be created
  #    separately and is not currently checked for existence.
  #def home=(value)
  #end
  #
  #def home
  #end
  
  #- **password**
  #    The user's password, in whatever encrypted format the local machine
  #    requires. Be sure to enclose any value that includes a dollar sign ($)
  #    in single quotes (').  Requires features manages_passwords.
  # TODO
  #def password=(value)
  #end
  #
  #def password
  #end
  
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

  #- **shell**
  #    The user's login shell.  The shell must exist and be
  #executable.
  #def shell=(value)
  #end
  #
  #def shell
  #end
  
  #- **uid**
  #    The user ID.  Must be specified numerically.  For new users
  #    being created, if no user ID is specified then one will be
  #    chosen automatically, which will likely result in the same user
  #    having different IDs on different systems, which is not
  #    recommended.  This is especially noteworthy if you use Puppet
  #    to manage the same user on both Darwin and other platforms,
  #    since Puppet does the ID generation for you on Darwin, but the
  #    tools do so on other platforms.
  #def uid=(value)
  #end
  #
  #def uid
  #end

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

  #- **name**
  #    User name.  While limitations are determined for
  #    each operating system, it is generally a good idea to keep to
  #    the degenerate 8 characters, beginning with a letter.
  # UNSUPPORTED

end
