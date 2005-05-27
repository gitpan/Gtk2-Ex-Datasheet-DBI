#!/usr/bin/perl

# (C) Daniel Kasak: dan@entropy.homelinux.org
# See COPYRIGHT file for full license

package Gtk2::Ex::Datasheet::DBI;

use strict;
use warnings;

use Glib qw/TRUE FALSE/;

use Gtk2::Ex::Dialogs (
			destroy_with_parent	=> TRUE,
			modal			=> TRUE,
			no_separator		=> FALSE
		      );

# Record Status Indicators
use constant {
			UNCHANGED		=> 0,
			CHANGED			=> 1,
			INSERTED		=> 2,
			DELETED			=> 3
};

# Record Status column
use constant{
			STATUS_COLUMN		=> 0
};

BEGIN {
	$Gtk2::Ex::DBI::Datasheet::VERSION = '0.4';
}

sub new {
	
	my ( $class, $req ) = @_;
	
	# Assemble object from request
	my $self = {
			dbh			=> $$req{dbh},		# A database handle
			table			=> $$req{table},	# The source table
			primary_key		=> $$req{primary_key},	# The primary key ( needed for inserts / updates )
			sql_select		=> $$req{sql_select},	# The fields in the 'select' clause of the query
			sql_where		=> $$req{sql_where},	# The 'where' clause of the query
			sql_order_by		=> $$req{sql_order_by},	# The 'order by' clause of the query
			treeview		=> $$req{treeview},	# The Gtk2::Treeview to connect to
			fields			=> $$req{fields},	# Field definitions
			multi_select		=> $$req{multi_select}	# Boolean to enable multi selection mode
	};
	
	bless $self, $class;
	
	$self->setup_treeview;
	
	# Remember the primary key column
	$self->{primary_key_column} = scalar(@{$self->{fieldlist}}) + 1;
	
	$self->query;
	
	return $self;
	
}

sub setup_treeview {
	
	# This sub sets up the TreeView, *and* a definition for the TreeStore ( which is used to create
	# a new TreeStore whenever we requery )
	
	my $self = shift;
	
	# Populate our fieldlist array so we don't have to continually query the DB server for it
	my $sth = $self->{dbh}->prepare($self->{sql_select} . " from " . $self->{table} . " where 0=1");
	$sth->execute;
	$self->{fieldlist} = $sth->{'NAME'};
	
	# If there are no field definitions, then use these fields from the database
	if ( ! $self->{fields} ) {
		for my $field ( @{$self->{fieldlist}} ) {
			push @{$self->{fields}}, { name	=> $field };
		}
	}
	
	my $column_no = 0;
	
	# First is the record status indicator: a CellRendererPixbuf ...
	my $renderer = Gtk2::CellRendererPixbuf->new;
	$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes("", $renderer);
	$self->{treeview}->append_column($self->{columns}[$column_no]);
	
	# Set up fixed size for status indicator and add to sum of fixed sizes
	$self->{columns}[$column_no]->set_sizing("fixed");
	$self->{columns}[$column_no]->set_fixed_width(20);
	$self->{sum_absolute_x} = 20;
	
	$self->{columns}[$column_no]->set_cell_data_func($renderer, sub { $self->render_pixbuf_cell( @_ ); } );
	
	# ... and the TreeStore column that goes with it
	push @{$self->{ts_def}}, "Glib::Int";
	
	$column_no ++;
		
	# Now set up the model and columns
	for my $field ( @{$self->{fields}} ) {
		
		if ( !$field->{renderer} || $field->{renderer} eq "text" ) {
			
			$renderer = Gtk2::CellRendererText->new;
			
			if ( ! $self->{readonly} ) {
				$renderer->set( editable => 1 );
			}
			
			$renderer->{column} = $column_no;
			
			$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes(
													$field->{name},
													$renderer,
													'text'	=> $column_no
												);
			
			$renderer->signal_connect( edited => sub { $self->process_text_editing( @_ ); } );
			
			$self->{treeview}->append_column($self->{columns}[$column_no]);
			
			# Add a string column to the TreeStore definition ( recreated when we query() )
			push @{$self->{ts_def}}, "Glib::String";
			
		} elsif ( $field->{renderer} eq "combo" ) {
			
			$renderer = Gtk2::CellRendererCombo->new;
			
			if ( ! $self->{readonly} ) {
				$renderer->set(
						editable	=> TRUE,
						model		=> $field->{model},
						text_column	=> 1,
						has_entry	=> TRUE
						);
			}
			
			$renderer->{column} = $column_no;
			
			$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes(
													$field->{name},
													$renderer,
													text	=> $column_no
												);
			
			$renderer->signal_connect( edited => sub { $self->process_text_editing( @_ ); } );
			
			$self->{treeview}->append_column($self->{columns}[$column_no]);
			
			$self->{columns}[$column_no]->set_cell_data_func($renderer, sub { $self->render_combo_cell( @_ ); } );
			
			# Add a string column to the TreeStore definition ( recreated when we query() )
			push @{$self->{ts_def}}, "Glib::String";
			
		} elsif ( $field->{renderer} eq "toggle" ) {
			
			$renderer = Gtk2::CellRendererToggle->new;
			
			if ( ! $self->{readonly} ) {
				$renderer->set( activatable	=> TRUE );
			}
			
			$renderer->{column} = $column_no;
			
			$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes(
													$field->{name},
													$renderer,
													active	=> $column_no
												);
			
			$renderer->signal_connect( toggled => sub { $self->process_toggle( @_ ); } );
			
			$self->{treeview}->append_column($self->{columns}[$column_no]);
			
			# Add an integer column to the TreeStore definition ( recreated when we query() )
			push @{$self->{ts_def}}, "Glib::Boolean";
			
		} elsif ( $field->{renderer} eq "none" ) {
			
			print "Adding hidden field " . $field->{name} . "\n";
			push @{$self->{ts_def}}, "Glib::String";
			
		} else {
			
			warn "Unknown render: " . $field->{renderer} . "\n";
			
		}
		
		# Set up column sizing stuff
		if ( $field->{x_absolute} || $field->{x_percent} ) {
			$self->{columns}[$column_no]->set_sizing("fixed");
		}
		
		# Add any absolute x values to our total and set their column size ( once only for these )
		if ($field->{x_absolute}) {
			$self->{sum_absolute_x} += $field->{x_absolute};
			$self->{columns}[$column_no]->set_fixed_width($field->{x_absolute});
		}
		
		$column_no ++;
		
	}
	
	# Add a column for the primary key to the TreeStore definition ... *MUST* have a numberic primary key
	push @{$self->{ts_def}}, "Glib::Int";
	
	# Now set up icons for use in the record status column
	$self->{icons}[UNCHANGED]	= $self->{treeview}->render_icon("gtk-yes",	"menu");
	$self->{icons}[CHANGED]		= $self->{treeview}->render_icon("gtk-refresh",	"menu");
	$self->{icons}[INSERTED]	= $self->{treeview}->render_icon("gtk-add",	"menu");
	$self->{icons}[DELETED]		= $self->{treeview}->render_icon("gtk-delete",	"menu");
	
	$self->{resize_signal} = $self->{treeview}->signal_connect( size_allocate => sub { $self->size_allocate( @_ ); } );
	
	# Turn on multi-select mode if requested
	if ($self->{multi_select}) {
		$self->{treeview}->get_selection->set_mode("multiple");
	}
	
}

sub render_pixbuf_cell {
	
	my ( $self, $tree_column, $renderer, $model, $iter ) = @_;
	
	my $status = $model->get($iter, STATUS_COLUMN);
	$renderer->set(pixbuf => $self->{icons}[$status]);
	
}

sub render_combo_cell {
	
	my ( $self, $tree_column, $renderer, $model, $iter ) = @_;
	
	# Get the ID that represents the text value to display
	my $key_value = $model->get($iter, $renderer->{column});
	
	my $combo_model = $renderer->get("model");
	
	# Loop through our combo's model and find a match for the above ID to get our text value
	my $combo_iter = $combo_model->get_iter_first;
	my $found_match = FALSE;
	
	while ($combo_iter) {
		
		if ($combo_model->get($combo_iter, 0) == $key_value) {
			$found_match = TRUE;
			$renderer->set( text	=> $combo_model->get( $combo_iter, 1 ) );
			last;
		}
		
		$combo_iter = $combo_model->iter_next($combo_iter);
		
	}
	
	# If we haven't found a match, default to displaying an empty value
	if ( !$found_match ) {
		$renderer->set( text	=> "" );
	}
	
	return FALSE;
	
}

sub process_text_editing {
	
	my ( $self, $renderer, $text_path, $new_text ) = @_;
	
	my $column_no = $renderer->{column};
	my $path = Gtk2::TreePath->new_from_string ($text_path);
	my $model = $self->{treeview}->get_model;
	my $iter = $model->get_iter ($path);
	
	# If this is a CellRendererCombo, then we have to look up the ID to match $new_text
	if ( ref($renderer) eq "Gtk2::CellRendererCombo" ) {
		
		my $combo_model = $renderer->get("model");
		my $combo_iter = $combo_model->get_iter_first;
		my $found_match = FALSE;
		
		while ($combo_iter) {
			
			if ($combo_model->get($combo_iter, 1) eq $new_text) {
				$found_match = TRUE;
				$new_text = $combo_model->get( $combo_iter, 0 ); # It's possible that this is a bad idea
				last;
			}
			
			$combo_iter = $combo_model->iter_next($combo_iter);
			
		}
		
		# If we haven't found a match, default to a zero
		if ( !$found_match ) {
			$new_text = 0; # This may also be a bad idea
		}
		
	}
	
	# Test to see if there is *really* a change or whether we've just received a double-click
	# or something else that hasn't actually changed the data
	my $old_text = $model->get( $iter, $column_no );
	
	if ( $old_text ne $new_text ) {
		
		if ( $self->{fields}->[$column_no - 1]->{validation} ) { # Array of field defs starts at zero
			if ( ! $self->{fields}->[$column_no - 1]->{validation}(
									{
										renderer	=> $renderer,
										text_path	=> $text_path,
										new_text	=> $new_text
									}
								     )
			   ) {
				return 0; # *** TODO *** rely on validation code to provide dialog on what's going on?
			}
		}
		
		$model->set( $iter, $column_no, $new_text );
		
	}
	
	# Move the focus to the next cell
	# Not quite as easy as I had anticipated...
	# Works most of the time, but in some circumstances goes *crazy*
	
	#if ( $column_no == $self->{primary_key_column} - 1 ) {
	#	
	#	# We're at the last column. Go to the 1st column in the next row
	#	my $new_iter = $model->iter_next($iter);
	#	
	#	if ($new_iter) {
	#		my $new_path = $model->get_path($new_iter);
	#		$self->{treeview}->set_cursor( $new_path, $self->{columns}[1], 1 );
	#	} else {
	#		$self->insert;
	#	}
	#	
	#} else {
	#	
	#	$self->{treeview}->set_cursor( $path, $self->{columns}[$column_no + 1], 1 );
	#	
	#}
	
	return FALSE;
	
}

sub process_toggle {
	  
	  my ( $self, $renderer, $text_path, $something ) = @_;
	  
	  my $path = Gtk2::TreePath->new ($text_path);
	  my $model = $self->{treeview}->get_model;
	  my $iter = $model->get_iter ($path);
	  my $old_value = $model->get( $iter, $renderer->{column} );
	  $model->set ( $iter, $renderer->{column}, ! $old_value );
	  
	  return FALSE;
	  
}

sub query {
	
	my ( $self, $sql_where, $dont_apply ) = @_;
	
	my $model = $self->{treeview}->get_model;
	
	if ( ! $dont_apply && $model ) {
		
		# First test to see if we have any outstanding changes to the current datasheet
		
		my $iter = $model->get_iter_first;
		
		while ($iter) {
			
			my $status = $model->get($iter, STATUS_COLUMN);
			
			# Decide what to do based on status
			if ( $status != UNCHANGED ) {
				
				my $answer = ask Gtk2::Ex::Dialogs::Question(
						    title	=> "Apply changes to " . $self->{table} . " before querying?",
						    text	=> "There are outstanding changes to the current datasheet ( " . $self->{table} . " )."
									. " Do you want to apply them before running a new query?"
									    );
				
				if ($answer) {
				    if ( ! $self->apply ) {
					return FALSE; # Apply method will already give a dialog explaining error
				    }
				}
				
			}
			
			$iter = $model->iter_next($iter);
			
		}
		
	}
	
	if (defined $sql_where) {
		$self->{sql_where} = $sql_where;
	}
	
	my $sth;
	my $sql = $self->{sql_select} . ", " . $self->{primary_key} . " from " . $self->{table};
	
	if ($self->{sql_where}) {
		$sql .= " " . $self->{sql_where};
	}
	
	eval {
		$sth = $self->{dbh}->prepare($sql) || die;
	};
	
	if ($@) {
			new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
								title   => "Error preparing select statement!",
								text    => "Database Server says:\n" . $self->{dbh}->errstr
							       );
			return 0;
	}
	
	# Create a new ListStore
	my $liststore = Gtk2::ListStore->new(@{$self->{ts_def}});
	
	eval {
		$sth->execute || die;
	};
	
	if ($@) {
			new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
								title   => "Error executing statement!",
								text    => "Database Server says:\n" . $self->{dbh}->errstr
							       );
			return 0;
	}
	
	while (my @row = $sth->fetchrow_array) {
		
		my @model_row;
		my $column = 0;
		
		# Append a new treeiter, and the status indicator
		push @model_row, $liststore->append, STATUS_COLUMN, UNCHANGED;
		
		for my $field (@{$self->{fields}}) {
			push @model_row, $column + 1, $row[$column];
			$column++;
			
		}
		
		# Append the primary key to the end
		push @model_row, $column + 1, $row[$column];
		
		$liststore->set(@model_row);
		
	}
	
	$self->{changed_signal} = $liststore->signal_connect( "row-changed" => sub { $self->changed(@_) } );
	
	$self->{treeview}->set_model($liststore);
	
}

sub changed {
	
	my ( $self, $liststore, $treepath, $iter ) = @_;
	
	my $model = $self->{treeview}->get_model;
	
	# Only change the record status if it's currently unchanged
	if ( ! $model->get($iter, STATUS_COLUMN) ) {
		$model->signal_handler_block($self->{changed_signal});
		$model->set($iter, STATUS_COLUMN, CHANGED);
		$model->signal_handler_unblock($self->{changed_signal});
	}
	
}

sub apply {
	
	my $self = shift;
	
	if ( $self->{readonly} ) {
		new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
					title   => "Read Only!",
					text    => "Datasheet is open in read-only mode!"
				       );
		return 0;
	}
	
	my $model = $self->{treeview}->get_model;
	my $iter = $model->get_iter_first;
	
	while ($iter) {
		
		my $status = $model->get($iter, STATUS_COLUMN);
		
		# Decide what to do based on status
		if ( $status == UNCHANGED ) {
			
			$iter = $model->iter_next($iter);
			next;
			
		} elsif ( $status == DELETED ) {
			
			my $primary_key = $model->get($iter, $self->{primary_key_column});
			
			my $sth = $self->{dbh}->prepare("delete from " . $self->{table}
				. " where " . $self->{primary_key} . "=?");
			
			eval {
				$sth->execute($primary_key) || die;
			};
			
			if ($@) {
					new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
										title   => "Error deleting record!",
										text    => "Database Server says:\n" . $self->{dbh}->errstr
									       );
					return 0;
			};
			
			$model->remove($iter);
			
		} else {
			
			# We process the insert / update operations in a similar fashion
			
			my $sql;			# Final SQL to send to DB server
			my $sql_fields;			# A comma-separated list of fields
			my @values;			# An array of values taken from the current record
			my $placeholders;		# A string of placeholders, eg ( ?, ?, ? )
			my $field_index = 1;		# Start at offset=1 to skip over changed flag
			
			foreach my $field ( @{$self->{fieldlist}} ) {
				if ( $status == INSERTED ) {
					$sql_fields .= " $field,";
					$placeholders .= " ?,";
				} else {
					$sql_fields .= " $field=?,";
				}
				push @values, $model->get($iter, $field_index);
				$field_index++;
			}
			
			# Remove trailing comma
			chop($sql_fields);
			
			if ( $status == INSERTED ) {
				chop($placeholders);
				$sql = "insert into " . $self->{table} . " ( $sql_fields ) values ( $placeholders )";
			} else {
				$sql = "update " . $self->{table} . " set $sql_fields"
					. " where " . $self->{primary_key} . "=?";
				push @values, $model->get($iter, $field_index);
			}
			
			my $sth;
			
			eval {
				$sth = $self->{dbh}->prepare($sql) || die;
			};
			
			if ($@) {
					new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
										title   => "Error preparing statement!",
										text    => "Database Server says:\n" . $self->{dbh}->errstr
									       );
					return 0;
			}
			
			eval {
				$sth->execute(@values) || die;
			};
			
			if ($@) {
					new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
										title   => "Error processing recordset!",
										text    => "Database Server says:\n" . $self->{dbh}->errstr
									       );
					warn "Error updating recordset:\n$sql\n" . $@ . "\n\n";
					return 0;
			}
			
			# If we just inserted a record, we have to fetch the primary key and replace the current '!' with it
			if ( $status == INSERTED ) {
				$model->set($iter, $self->{primary_key_column}, $self->last_insert_id);
			}
			
			# If we've gotten this far, the update was OK, so we'll reset the 'changed' flag
			# and move onto the next record
			$model->signal_handler_block($self->{changed_signal});
			$model->set($iter, STATUS_COLUMN, UNCHANGED);
			$model->signal_handler_unblock($self->{changed_signal});
			
		}
		
		$iter = $model->iter_next($iter);
		
	}
	
	return TRUE;
	
}

sub insert {
	
	my ( $self, @columns_and_values ) = @_;
	
	if ( $self->{readonly} ) {
		new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
					title   => "Read Only!",
					text    => "Datasheet is open in read-only mode!"
				       );
		return 0;
	}
		
	my $model = $self->{treeview}->get_model;
	my $iter = $model->append;
	
	my @new_record;
	
	push @new_record, $iter, STATUS_COLUMN, INSERTED;
	
	if (scalar(@columns_and_values)) {
		push @new_record, @columns_and_values;
	}
	
	$model->set( @new_record );
	
	$self->{treeview}->set_cursor( $model->get_path($iter), $self->{columns}[1], 1 );
	
	return 1;
	
}

sub delete {
	
	my $self = shift;
	
	if ( $self->{readonly} ) {
		new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
					title   => "Read Only!",
					text    => "Datasheet is open in read-only mode!"
				       );
		return 0;
	}
		
	# We only mark the selected record for deletion at this point
	my @selected_paths = $self->{treeview}->get_selection->get_selected_rows;
	my $model = $self->{treeview}->get_model;
	
	for my $path (@selected_paths) {
		$model->set( $model->get_iter($path), STATUS_COLUMN, DELETED );
	}
	
}

sub size_allocate {
	
	my ( $self, $widget, $rectangle ) = @_;
	
	my ( $x, $y, $width, $height ) = $rectangle->values;
	
	if ( $self->{current_width} != $width ) { # *** TODO *** Fix this. Should block signal ( see below )
		
		# Absolute values are calculated in setup_treeview as they only have to be calculated once
		# We take the sum of the absolute values away from the width we've just been passed, and *THEN*
		# allocate the remainder to fields according to their x_percent values
		
		my $available_x = $width - $self->{sum_absolute_x};
		
		my $column_no = 1;
		$self->{current_width} = $width;
		
		# *** TODO *** Doesn't currently work ( completely )
		$self->{treeview}->signal_handler_block($self->{resize_signal});
		
		for my $field (@{$self->{fields}}) {
			if ($field->{x_percent}) { # Only need to set ones that have a percentage
				$self->{columns}[$column_no]->set_fixed_width( $available_x * ( $field->{x_percent} / 100 ) );
			}
			$column_no ++;
		}
		
		# *** TODO *** Doesn't currently work ( completely )
		$self->{treeview}->signal_handler_unblock($self->{resize_signal});
		
	}
	
}

sub column_from_name {
	
	# This function takes a field name and returns the column that the field is in by
	# walking through the array $self->{fieldlist}
	
	my ( $self, $sql_fieldname ) = @_;
	
	my $counter = 1; # Start at 1 because column is status column
	
	for my $field (@{$self->{fieldlist}}) {
		if ($field eq $sql_fieldname) {
			return $counter;
		}
		$counter ++;
	}
	
}

sub column_value {
	
	# This function returns the value in the requested column in the currently selected row
	# If multi_select is turned on and more than 1 row is selected, it looks in the 1st row
	
	my ( $self, $sql_fieldname ) = @_;
	
	if ($self->{mult_select}) {
		print "Gtk2::Ex::Datasheet::DBI - column_value() called with multi_select enabled!\n"
			. " ... returning value from 1st selected row\n";
	}
	
	my @selected_paths = $self->{treeview}->get_selection->get_selected_rows;
	
	if ( ! scalar(@selected_paths) ) {
		return 0;
	}
		
	my $model = $self->{treeview}->get_model;
	
	return $model->get( $model->get_iter($selected_paths[0]), $self->column_from_name($sql_fieldname) );
	
}

sub last_insert_id {
	
	my $self = shift;
	
	my $sth = $self->{dbh}->prepare('select @@IDENTITY');
	$sth->execute;
	
	if (my $row = $sth->fetchrow_array) {
		return $row;
	} else {
		return undef;
	}
	
}

1;

=head1 NAME

Gtk2::Ex::Datasheet::DBI

=head1 SYNOPSIS

use DBI;
use Gtk2 -init;
use Gtk2::Ex::Datasheet::DBI; 

my $dbh = DBI->connect (
                        "dbi:mysql:dbname=sales;host=screamer;port=3306",
                        "some_username",
                        "salespass", {
                                       PrintError => 0,
                                       RaiseError => 0,
                                       AutoCommit => 1,
                                     }
);

my $datasheet_def = {
                      dbh          => $dbh,
                      table        => "BirdsOfAFeather",
                      primary_key  => "ID",
                      sql_select   => "select FirstName, LastName, GroupNo, Active",
                      sql_order_by => "order by LastName",
                      treeview     => $testwindow->get_widget("BirdsOfAFeather_TreeView"),
                      fields       => [
                                         {
                                            name          => "First Name",
                                            x_percent     => 35,
                                            validation    => sub { &validate_first_name(@_); }
                                         },
                                         {
                                            name          => "Last Name",
                                            x_percent     => 35
                                         },
                                         {
                                            name          => "Group",
                                            x_percent     => 30,
                                            renderer      => "combo",
                                            model         => $group_model
                                         },
                                         {
                                            name          => "Active",
                                            x_absolute    => 50,
                                            renderer      => "toggle"
                                         }
                                      ],
                      multi_select => TRUE
};

$birds_of_a_feather_datasheet = Gtk2::Ex::Datasheet::DBI->new($datasheet_def)
   || die ("Error setting up Gtk2::Ex::Datasheet::DBI\n");

=head1 DESCRIPTION

This module automates the process of setting up a model and treeview based on field definitions you pass it,
querying the database, populating the model, and updating the database with changes made by the user.

Steps for use:

* Open a DBI connection

* Create a 'bare' Gtk2::TreeView - I use Gtk2::GladeXML, but I assume you can do it the old-fashioned way

* Create a Gtk2::Ex::Datasheet::DBI object and pass it your TreeView object

You would then typically create some buttons and connect them to the methods below to handle common actions
such as inserting, deleting, etc.

=head1 METHODS

=head2 new

Object constructor. Expects a hash of key / value pairs. Bare minimum are:
  
  dbh             - a DBI database handle
  table           - the name of the table you are querying
  primary_key     - the primary key of the table you are querying ( required for updating / deleting )
  sql_select      - the 'select' clause of the query
  
Other keys accepted are:
  
  sql_where       - the 'where' clause of the query
  sql_order_by    - the 'order by' clause of the query
  multi_selcet    - a boolean to turn on the TreeView's 'multiple' selection mode
  fields          - an array of hashes to describe the fields ( columns ) in the TreeView
  
Each item in the 'fields' key is a hash, with the following keys:
  
  name            - the name to display in the column's heading
  x_percent       - a percentage of the available width to use for this column
  x_absolute      - an absolute value to use for the width of this column
  renderer        - string name of renderer - possible values are currently:
                        - text    - default if no renderer defined )
                        - combo   - requires a model to be defined as well )
                        - toggle  - good for boolean values )
                        - none    - use this for hidden columns
  model           - a TreeModel to use with a combo renderer
  validation      - a sub to run after data entry and before the value is accepted to validate data

=head2 query ( [ new_where_clause ], [ dont_apply ] )

Requeries the DB server. If there are any outstanding changes that haven't been applied to the database,
a dialog will be presented to the user asking if they want to apply updates before requerying.

If a new where clause is passed, it will replace the existing one.
If dont_apply is set, *no* dialog will appear if there are outstanding changes to the data.

The query method doubles as an 'undo' method if you set the dont_apply flag, eg:

$datasheet->query ( undef, TRUE );

This will requery and reset all the status indicators.

=head2 apply

Applies all changes ( inserts, deletes, alterations ) in the datasheet to the database.
As changes are applied, the record status indicator will be changed back to the original 'synchronised' icon.

If any errors are encountered, a dialog will be presented with details of the error, and the apply method
will return FALSE without continuing through the records. The user will be able to tell where the apply failed
by looking at the record status indicators ( and considering the error message they were presented ).

=head2 insert ( [ @columns_and_values ] )

Inserts a new row in the *model*. The record status indicator will display an 'insert' icon until the record
is applied to the database ( apply method ).

You can optionally set default values by passing them as an array of column numbers and values, eg:
   $datasheet->insert(
                       2   => "Default value for column 2",
                       5   => "Another default - for column 5"
                     );

Note that you can use the column_from_name method for fetching column numbers from field names ( see below ).

=head2 delete

Marks all selected records for deletion, and sets the record status indicator to a 'delete' icon.
The records will remain in the database until the apply method is called.

=head2 column_from_name ( sql_fieldname )

Returns a field's column number in the model. Note that you *must* use the SQL fieldname,
and not the column heading's name in the treeview.

=head2 column_value ( sql_fieldname )

Returns the value of the requested column in the currently selected row.
If multi_select is on and more than 1 row is selected, only the 1st value is returned.
You *must* use the SQL fieldname, and not the column heading's name in the treeview.


=head1 General Ranting

=head2 Automatic Column Widths

You can use x_percent and x_absolute values to set up automatic column widths. Absolute values are set
once - at the start. In this process, all absolute values ( including the record status column ) are
added up and the total stored in $self->{sum_absolute_x}.

Each time the TreeView is resized ( size_allocate signal ), the size_allocate method is called which resizes
all columns that have an x_percent value set. The percentages should of course all add up to 100%, and the width
of each column is their share of available width:
 ( total width of treeview ) - $self->{sum_absolute_x} * x_percent

IMPORTANT NOTE:
The size_allocate method interferes with the ability to resize *down*. I've found a simple way around this.
When you create the TreeView, put it in a ScrolledWindow, and set the H_Policy to 'automatic'. I assume this allows
you to resize the treeview down to smaller than the total width of columns ( which automatically creates the
scrollbar in the scrolled window ). Immediately after the resize, when our size_allocate method recalculates the
size of each column, the scrollbar will no longer be needed and will disappear. Not perfect, but it works. It also
doesn't produce *too* much flicker on my system, but resize operations are noticably slower. What can I say?
Patches appreciated :)

=head2 CellRendererCombo

If you have Gtk-2.6 or greater, you can use the new CellRendererCombo. Set the renderer to 'combo' and attach
your model to the field definition. You currently *must* have a model with ( numeric ) ID / String pairs, which is the
usual for database applications, so you shouldn't have any problems. See the example application for ... an example.

=head1 Authors

Daniel Kasak - dan@entropy.homelinux.org

=head1 Bugs

I think you must be mistaken

=head1 Other cool things you should know about

This module is part of a 3-some:

Gtk2::Ex::DBI                 - forms

Gtk2::Ex::Datasheet::DBI      - datasheets

PDF::ReportWriter             - reports

Together ( and with a little help from other modules such as Gtk2::GladeXML ),
these modules give you everything you need for rapid application development of database front-ends
on Linux, Windows, or ( with a little frigging around ) Mac OS-X.

All the above modules are available via cpan, or from:
http://entropy.homelinux.org

=head1 Crank ON!