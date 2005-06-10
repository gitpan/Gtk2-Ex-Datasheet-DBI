#!/usr/bin/perl

# (C) Daniel Kasak: dan@entropy.homelinux.org
# See COPYRIGHT file for full license

# See 'man Gtk2::Ex::DBI' for full documentation ... or of course continue reading

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
	$Gtk2::Ex::DBI::Datasheet::VERSION = '0.6';
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
	
	# Cache the fieldlist array so we don't have to continually query the DB server for it
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
			
			#$renderer = Gtk2::CellRendererText->new;
			$renderer = MOFO::CellRendererText->new;
			
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
			
		} elsif ( $field->{renderer} eq "number" ) {
			
			$renderer = MOFO::CellRendererSpinButton->new;
			
			if ( ! $self->{readonly} ) {
				$renderer->set( mode => "editable" );
			}
			
			$renderer->set(
					min	=> $field->{min}	|| 0,
					max	=> $field->{max}	|| 9999,
					digits	=> $field->{digits}	|| 0,
					step	=> $field->{step}	|| 1
				      );
			
			$renderer->{column} = $column_no;
			
			$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes(
													$field->{name},
													$renderer,
													'value'	=> $column_no
												);
			
			$renderer->signal_connect( edited => sub { $self->process_text_editing( @_ ); } );
			
			$self->{treeview}->append_column($self->{columns}[$column_no]);
			
			# Add a numeric field to the TreeStore definition ( recreated when we query() )
			push @{$self->{ts_def}}, "Glib::Double";
			
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
				return FALSE; # Error dialog should have already been produced by validation code
			}
		}
		
		$model->set( $iter, $column_no, $new_text );
		
	}
	
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

package MOFO::CellEditableText;

# Copied and pasted from Odot

use strict;
use warnings;

use Glib qw(TRUE FALSE);
use Glib::Object::Subclass
  Gtk2::TextView::,
  interfaces => [ Gtk2::CellEditable:: ];

sub set_text {
	
	my ($editable, $text) = @_;
	$text = "" unless (defined($text));
	
	$editable -> get_buffer() -> set_text($text);
	
}

sub get_text {
	
	my ($editable) = @_;
	my $buffer = $editable -> get_buffer();
	
	return $buffer -> get_text($buffer -> get_bounds(), TRUE);
	
}

sub select_all {
	
	my ($editable) = @_;
	my $buffer = $editable -> get_buffer();
	
	my ($start, $end) = $buffer -> get_bounds();
	$buffer -> move_mark_by_name(insert => $start);
	$buffer -> move_mark_by_name(selection_bound => $end);
	
}

1;

package MOFO::CellRendererText;

# Also copied and pasted from Odot, with bits and pieces from the CellRendererSpinButton example,
# and even some of my own stuff worked in :)

use strict;
use warnings;

use Gtk2::Gdk::Keysyms;
use Glib qw(TRUE FALSE);
use Glib::Object::Subclass
  Gtk2::CellRendererText::,
  properties => [
    Glib::ParamSpec -> object("editable-widget",
                              "Editable widget",
                              "The editable that's used for cell editing.",
                              MOFO::CellEditableText::,
                              [qw(readable writable)])
  ];

sub INIT_INSTANCE {
	
	my ($cell) = @_;
	
	my $editable = MOFO::CellEditableText -> new();
	
	$editable -> set(border_width => $cell -> get("ypad"));
	
	$editable -> signal_connect(key_press_event => sub {
		
		my ($editable, $event) = @_;
		
		if ($event -> keyval == $Gtk2::Gdk::Keysyms{ Return } ||
			$event -> keyval == $Gtk2::Gdk::Keysyms{ KP_Enter }
			and not $event -> state & qw(control-mask)) {
				
				# Grab parent
				my $parent = $editable->get_parent;
				
				$editable -> { _editing_canceled } = FALSE;
				$editable -> editing_done();
				$editable -> remove_widget();
				
				my ($path, $focus_column) = $parent->get_cursor;
				my @cols = $parent->get_columns;
				my $next_col = undef;
				
				foreach my $i (0..$#cols) {
					if ($cols[$i] == $focus_column) {
						if ($event->state >= 'shift-mask') {
							# go backwards
							$next_col = $cols[$i-1] if $i > 0;
						} else {
							# go forwards
							$next_col = $cols[$i+1] if $i < $#cols;
						}
						last;
					}
				}
				
				$parent->set_cursor ($path, $next_col, 1)
					if $next_col;
				
				return TRUE;
				
		}
	
		return FALSE;
		
	});
	
	$editable -> signal_connect(editing_done => sub {
		
		my ($editable) = @_;
		
		# gtk+ changed semantics in 2.6.  you now need to call stop_editing().
		if (Gtk2 -> CHECK_VERSION(2, 6, 0)) {
			$cell -> stop_editing($editable -> { _editing_canceled });
		}
		
		# if gtk+ < 2.4.0, emit the signal regardless of whether editing was
		# canceled to make undo/redo work.
		
		my $new = Gtk2 -> CHECK_VERSION(2, 4, 0);
		
		if (!$new || ($new && !$editable -> { _editing_canceled })) {
			$cell -> signal_emit(edited => $editable -> { _path }, $editable -> get_text());
		} else {
			$cell -> editing_canceled();
		}
	});
	
	$cell -> set(editable_widget => $editable);
	
}

sub START_EDITING {
	
	my ($cell, $event, $view, $path, $background_area, $cell_area, $flags) = @_;
	
	if ($event) {
		return unless ($event -> button == 1);
	}
	
	my $editable = $cell -> get("editable-widget");
	
	$editable -> { _editing_canceled } = FALSE;
	$editable -> { _path } = $path;
	
	$editable -> set_text($cell -> get("text"));
	$editable -> select_all();
	$editable -> show();
	
	return $editable;
	
}

package MOFO::CellRendererSpinButton;

use POSIX qw(DBL_MAX UINT_MAX);

use constant x_padding => 2;
use constant y_padding => 3;

use Glib::Object::Subclass
  "Gtk2::CellRenderer",
  signals => {
		edited => {
			    flags => [qw(run-last)],
			    param_types => [qw(Glib::String Glib::Double)],
			  },
	     },
  properties => [
		  Glib::ParamSpec -> double("xalign", "Horizontal Alignment", "Where am i?", 0.0, 1.0, 1.0, [qw(readable writable)]),
		  Glib::ParamSpec -> boolean("editable", "Editable", "Can I change that?", 0, [qw(readable writable)]),
		  Glib::ParamSpec -> uint("digits", "Digits", "How picky are you?", 0, UINT_MAX, 2, [qw(readable writable)]),
		  map {
			  Glib::ParamSpec->double(
						    $_ -> [0],
						    $_ -> [1],
						    $_ -> [2],
						    0.0,
						    DBL_MAX,
						    $_ -> [3],
						    [qw(readable writable)]
						 )
		  }
		  (
		    ["value", "Value", "How much is the fish?",      0.0],
		    ["min",   "Min",   "No way, I have to live!",    0.0],
		    ["max",   "Max",   "Ah, you're too generous.", 100.0],
		    ["step",  "Step",  "Okay.",                      5.0])
		  ];
  
sub INIT_INSTANCE {
	
	my $self = shift;
	
	$self->{editable} =     0;
	$self->{digits}   =     2;
	$self->{value}    =   0.0;
	$self->{min}      =   0.0;
	$self->{max}      = 100.0;
	$self->{step}     =   5.0;
	$self->{xalign}   =   1.0;
	
}

sub calc_size {
	
	my ($cell, $layout, $area) = @_;
	
	my ($width, $height) = $layout -> get_pixel_size();
	
	return (
		$area ? $cell->{xalign} * ($area->width - ($width + 3 * x_padding)) : 0,
		0,
		$width + x_padding * 2,
		$height + y_padding * 2
	       );
	
}

sub format_text {
	
	my $cell = shift;
	my $format = sprintf '%%.%df', $cell->{digits};
	sprintf $format, $cell->{value};
	
}

sub GET_SIZE {
	
	my ($cell, $widget, $area) = @_;
	
	my $layout = $cell -> get_layout($widget);
	$layout -> set_text($cell -> format_text);
	
	return $cell -> calc_size($layout, $area);
	
}

sub get_layout {
	
	my ($cell, $widget) = @_;
	
	return $widget -> create_pango_layout("");
	
}

sub RENDER {
	
	my ($cell, $window, $widget, $background_area, $cell_area, $expose_area, $flags) = @_;
	my $state;
	
	if ($flags & 'selected') {
		$state = $widget -> has_focus()
		? 'selected'
		: 'active';
	} else {
		$state = $widget -> state() eq 'insensitive'
		? 'insensitive'
		: 'normal';
	}
	
	my $layout = $cell -> get_layout($widget);
	$layout -> set_text ($cell -> format_text);
	
	my ($x_offset, $y_offset, $width, $height) = $cell -> calc_size($layout, $cell_area);
	
	$widget -> get_style -> paint_layout(
						$window,
						$state,
						1,
						$cell_area,
						$widget,
						"cellrenderertext",
						$cell_area -> x() + $x_offset + x_padding,
						$cell_area -> y() + $y_offset + y_padding,
						$layout
					    );
	
}

sub START_EDITING {
	
	my ($cell, $event, $view, $path, $background_area, $cell_area, $flags) = @_;
	my $spin_button = Gtk2::SpinButton -> new_with_range($cell -> get(qw(min max step)));
	
	$spin_button -> set_value($cell -> get("value"));
	$spin_button -> set_digits($cell -> get("digits"));
	
	$spin_button -> grab_focus();
	
	$spin_button -> signal_connect(key_press_event => sub {
		
		my (undef, $event) = @_;
		
		# grab this for later.
		my $parent = $spin_button->get_parent;
		
		if ($event -> keyval == $Gtk2::Gdk::Keysyms{ Return } ||
			$event -> keyval == $Gtk2::Gdk::Keysyms{ KP_Enter } ||
			$event -> keyval == $Gtk2::Gdk::Keysyms{ Tab }) {
			
				$spin_button -> update();
				$cell -> signal_emit(edited => $path, $spin_button -> get_value());
				$spin_button -> destroy();
				
				if ( ( $event -> keyval == $Gtk2::Gdk::Keysyms{ Return } ||
					$event->keyval == $Gtk2::Gdk::Keysyms{ KP_Enter } )
					&& $parent -> isa ('Gtk2::TreeView')) {
					
					# If the user has hit Enter, move to the next column
					my ($path, $focus_column) = $parent->get_cursor;
					my @cols = $parent->get_columns;
					my $next_col = undef;
					
					foreach my $i (0..$#cols) {
						if ($cols[$i] == $focus_column) {
							if ($event->state >= 'shift-mask') {
								# go backwards
								$next_col = $cols[$i-1] if $i > 0;
							} else {
								# go forwards
								$next_col = $cols[$i+1] if $i < $#cols;
							}
							last;
						}
					}
					
					$parent->set_cursor ($path, $next_col, 1)
						if $next_col;
				}
				
				return 1;
				
			} elsif ($event -> keyval == $Gtk2::Gdk::Keysyms{ Up }) {
				$spin_button -> spin('step-forward', ($spin_button -> get_increments())[0]);
				return 1;
			} elsif ($event -> keyval == $Gtk2::Gdk::Keysyms{ Down }) {
				$spin_button -> spin('step-backward', ($spin_button -> get_increments())[0]);
				return 1;
			}
			
			return 0;
			
		}
				      );
	
	$spin_button -> signal_connect(focus_out_event => sub {
		
		$spin_button -> update();
		$cell -> signal_emit(edited => $path, $spin_button -> get_value());
		
	}
				      );
	
	$spin_button -> show_all();
	
	return $spin_button;
	
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
			- number  - invokes a customer CellRendererSpin button - see below
                        - combo   - requires a model to be defined as well )
                        - toggle  - good for boolean values )
                        - none    - use this for hidden columns
  model           - a TreeModel to use with a combo renderer
  validation      - a sub to run after data entry and before the value is accepted to validate data

In the case of a 'number' renderer, the following keys are also used:

  min             - the minimum value of the spinbutton
  max             - the maximum value of the spinbutton
  digits          - the number of decimal places in the spinbutton
  step            - the value that the spinbutton's buttons spin the value by :)

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