#!/usr/bin/perl

use strict;

use Gtk2 -init;
use Gtk2::GladeXML;
use Glib qw/TRUE FALSE/;
use DBI;
use lib("../lib");
use Gtk2::Ex::Datasheet::DBI;

# Some globals
my ( $testwindow, $dbh, $birds_of_a_feather_datasheet );

sub LoadForm {
	
	$dbh = DBI->connect ("dbi:mysql:dbname=datasheet;port=3306", "root", "", {
											PrintError => 0,
											RaiseError => 0,
											AutoCommit => 1
										 }
			    );
	
	$testwindow = Gtk2::GladeXML->new("test_datasheet.glade", 'TestWindow');
	$testwindow->signal_autoconnect_from_package;
	
	my $group_model = create_combomodel(
						$dbh,
						"select ID, Description from Groups",
						{
							id		=> "ID",
							id_def		=> "Glib::Int",
							display		=> "Description",
							display_def	=> "Glib::String"
						}
					   );
	
	my $datasheet_def = {
				dbh		=> $dbh,
				table		=> "BirdsOfAFeather",
				primary_key	=> "ID",
				sql_select	=> "select FirstName, LastName, GroupNo, Active",
				sql_order_by	=> "order by LastName",
				treeview	=> $testwindow->get_widget("BirdsOfAFeather_TreeView"),
				fields		=> [
						    {
							name		=> "First Name",
							x_percent	=> 35, # sum(percentage) should be 100
							validation	=> sub { &validate_first_name(@_); }
						    },
						    {
							name		=> "Last Name",
							x_percent	=> 35
						    },
						    {
							name		=> "Group",
							x_percent	=> 30,
							renderer	=> "combo",
							model		=> $group_model
						    },
						    {
							name		=> "Active",
							x_absolute	=> 50, # absolute values - subtracted *before* widths of variable (percentage) columns are calculated
							renderer	=> "toggle"
						    }
						   ],
				multi_select	=> TRUE
			    };
	
	$birds_of_a_feather_datasheet = Gtk2::Ex::Datasheet::DBI->new($datasheet_def)
		|| die ("Error setting up Gtk2::Ex::Datasheet::DBI\n");
	
}

sub on_btn_Add_clicked {
	
	# As we insert a new record, default to being a member of the US government ( Group 1 = US Governmant )
	$birds_of_a_feather_datasheet->insert( $birds_of_a_feather_datasheet->column_from_name("GroupNo") => 1 );
	
}

sub on_btn_Delete_clicked {
	
	$birds_of_a_feather_datasheet->delete;
	
}

sub on_btn_Undo_clicked {
	
	# To prevent a dialog asking whether we should apply changes,
	# run query with an undef value for the where clause ( so we don't pick up a new where clause ),
	# and a TRUE value for the 'dont_apply' flag
	$birds_of_a_feather_datasheet->query( undef, TRUE );
	
}

sub on_btn_Apply_clicked {
	
	$birds_of_a_feather_datasheet->apply;
	
}

sub validate_first_name {
	
	my $options = shift;
	
	if ($options->{new_text} eq "George") {
			new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
								title   => "Illegal First Name",
								text    => "Sorry. We don't like George around here!"
							       );
			return 0;
	}
	
	return 1;
	
}

sub on_TestWindow_destroy {
	
	$birds_of_a_feather_datasheet = undef;
	$dbh->disconnect;
	exit;
	
}

sub create_combomodel {
	
	# Returns a model for use in a GtkComboBoxEntry
	
	my ( $dbh, $sql, $fields ) = @_;
	
	my $liststore = Gtk2::ListStore->new(
						$fields->{id_def},
						$fields->{display_def}
					    );
	
	my $sth = $dbh->prepare($sql);
	$sth->execute;
	
	my $iter;
	
	while (my $row = $sth->fetchrow_hashref) {
		$iter = $liststore->append;
		$liststore->set($iter, 0, $row->{$fields->{id}}, 1, $row->{$fields->{display}});
	}
	
	return $liststore;
	
}


{
    
    LoadForm;
    Gtk2->main;
    
}
