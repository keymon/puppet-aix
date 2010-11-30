#
# Group Puppet provider for AIX. It uses standard commands to manage groups:
#  mkgroup, rmgroup, lsgroup, chgroup
#
# Author::    Hector Rivas Gandara <keymon@gmail.com>
#  
require 'puppet/provider/aixobject'

Puppet::Type.type(:group).provide :aix, :parent => Puppet::Provider::AixObject do
  desc "Group management for AIX! Users are managed with mkgroup, rmgroup, lsgroup, chgroup"

  # Constants
  # Default extra attributes to add when element is created
  # registry=compat: Needed if you are using LDAP by default.
  @DEFAULT_EXTRA_ATTRS = [ "registry=compat",  ]


  # This will the the default provider for this platform
  defaultfor :operatingsystem => :aix
  confine :operatingsystem => :aix

  # Provider features
  has_features :manages_members

  # Commands that manage the element
  commands :list      => "/usr/sbin/lsgroup"
  commands :add       => "/usr/bin/mkgroup"
  commands :delete    => "/usr/sbin/rmgroup"
  commands :modify    => "/usr/bin/chgroup"

  # AIX attributes to properties mapping.
  # 
  # Valid attributes to be managed by this provider.
  # It is a list with of hash
  #  :aix_attr      AIX command attribute name
  #  :puppet_prop   Puppet propertie name
  #  :to            Method to adapt puppet property to aix command value. Optional.
  #  :from            Method to adapt aix command value to puppet property. Optional
  self.attribute_mapping = [
    #:name => :name,
    {:aix_attr => :id,       :puppet_prop => :gid },
    {:aix_attr => :users,    :puppet_prop => :members,
      :from => :users_from_attr},
  ]
  
  #--------------
  # Command lines
  def lscmd(value=@resource[:name])
    [self.class.command(:list), "-R", self.class.ia_module , value]
  end

  def addcmd(extra_attrs = [])
    # Here we use the @resource.to_hash to get the list of provided parameters
    # Puppet does not call to self.<parameter>= method if it does not exists.
    #
    # It gets an extra list of arguments to add to the user.
    [self.class.command(:add), "-R", self.class.ia_module  ]+
      self.class.hash2attr(@resource.to_hash) +
      extra_attrs + [@resource[:name]]
  end

  def modifycmd(hash = property_hash)
    [self.class.command(:modify), "-R", self.class.ia_module ]+
      self.class.hash2attr(hash) + [@resource[:name]]
  end

  def deletecmd
    [self.class.command(:delete),"-R", self.class.ia_module, @resource[:name]]
  end

  # Force convert it to a list.
  def self.users_from_attr(value)
    (value.is_a? String) ? value.split(',') : value
  end

#- **allowdupe**
#    Whether to allow duplicate GIDs.  This option does not work on
#    FreeBSD (contract to the `pw` man page).  Valid values are `true`,
#    `false`.
#
#- **auth_membership**
#    whether the provider is authoritative for group membership.
#
#- **ensure**
#    Create or remove the group.  Valid values are `present`, `absent`.
#
#- **gid**
#    The group ID.  Must be specified numerically.  If not
#    specified, a number will be picked, which can result in ID
#    differences across systems and thus is not recommended.  The
#    GID is picked according to local system standards.
#
#- **members**
#    The members of the group. For directory services where group
#    membership is stored in the group objects, not the users.  Requires
#    features manages_members.
#
#- **name**
#    The group name.  While naming limitations vary by
#    system, it is advisable to keep the name to the degenerate
#    limitations, which is a maximum of 8 characters beginning with
#a letter.

end
