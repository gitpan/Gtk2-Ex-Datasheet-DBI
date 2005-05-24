use Test::More qw(no_plan);
#########################

BEGIN { use_ok( 'Gtk2::Ex::Datasheet::DBI' ); }

#########################
# are all the known methods accounted for?

my @methods = qw(
			new
			create_simplelist
			fieldlist
			query
			insert
			apply
			changed
			delete
			last_insert_id
		);

can_ok( 'Gtk2::Ex::Datasheet::DBI', @methods );
