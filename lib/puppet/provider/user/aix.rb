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
require 'puppet/provider/aixobject'
require 'tempfile'
require 'date'

Puppet::Type.type(:user).provide :aix, :parent => Puppet::Provider::AixObject do
  desc "User management for AIX! Users are managed with mkuser, rmuser, chuser, lsuser"

  # This will the the default provider for this platform
  defaultfor :operatingsystem => :aix
  confine :operatingsystem => :aix

  # Commands that manage the element
  commands :list      => "/usr/sbin/lsuser"
  commands :add       => "/usr/bin/mkuser"
  commands :delete    => "/usr/sbin/rmuser"
  commands :modify    => "/usr/bin/chuser"
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
  # Default extra attributes to add when element is created
  # registry=compat SYSTEM=compat: Needed if you are using LDAP by default.
  @@DEFAULT_EXTRA_ATTRS = [ "registry=compat", " SYSTEM=compat" ]

  # AIX attributes to properties mapping.
  # Include here the valid attributes to be managed by this provider.
  # The hash should map the AIX attribute (command output) names to
  # puppet names.
  attribute_mapping = {
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
  

  #-----
  def lscmd(value=@resource[:name])
    [self.class.command(:list),"-R", ia_module , value]
  end

  # Here we use the @resource.to_hash to get the list of provided parameters
  # Puppet does not call to self.<parameter>= method if it does not exists.
  #
  # It gets an extra list of arguments to add to the user.
  def addcmd(extra_attrs = [])
    [self.class.command(:add),"-R", ia_module  ]+
      hash2attr(@resource.to_hash, attribute_mapping_rev) +
      extra_attrs + [@resource[:name]]
  end

  def modifycmd(attributes_hash)
    [self.class.command(:modify),"-R", ia_module ]+
      hash2attr(@property_hash, attribute_mapping_rev) + [@resource[:name]]
  end

  def deletecmd
    [self.class.command(:delete),"-R", ia_module, @resource[:name]]
  end


  #--------------------------------
  # When the object is initialized, 
  # create getter/setter methods for each property our resource type supports.
  # If setter or getter already defined it will not be overwritten
  #self.mk_resource_methods
  
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
    cmd = [self.class.command(:chpasswd),"-R", ia_module,
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

end
