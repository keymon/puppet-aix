class puppet_aix::test_user {
	user{'prueba':
		ensure => present,
		uid => 6969,
		gid => "staff",
		home => "/tmp/",
		groups => ["sshcon", "system", "bin" ],
		membership => minimum,
		password => 'rTh42deAGc2DY',
		expiry => "2010-10-21",
		password_max_age => 4
	}

	group{'gprueba':
		ensure => present,
		gid => 6969,
		members => ["prueba"]
	}

}
