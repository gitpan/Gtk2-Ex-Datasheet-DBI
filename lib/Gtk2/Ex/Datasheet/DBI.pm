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
	$Gtk2::Ex::DBI::Datasheet::VERSION = '0.3';
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
	
	# Remember the primary key column
	$self->{primary_key_column} = scalar(@{$self->{fields}}) + 1;
	
	$self->setup_treeview;
	$self->query;
	
	return $self;
	
}

sub setup_treeview {
	
	# This sub sets up the TreeView, *and* a definition for the TreeStore ( which is used to create
	# a new TreeStore whenever we requery )
	
	my $self = shift;
	
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
	
	# Next are the fields in $self->{fields}
	for my $field (@{$self->{fields}}) {
		
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
	
}

sub process_toggle {
	  
	  my ( $self, $renderer, $text_path, $something ) = @_;
	  
	  my $path = Gtk2::TreePath->new ($text_path);
	  my $model = $self->{treeview}->get_model;
	  my $iter = $model->get_iter ($path);
	  my $old_value = $model->get( $iter, $renderer->{column} );
	  $model->set ( $iter, $renderer->{column}, ! $old_value );
	  
}

sub query {
	
	my ( $self, $sql_where ) = @_;
	
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
			
			my $inserting = 0;		# Insertion flag
			my $sql;			# Final SQL to send to DB server
			my $sql_fields;			# A comma-separated list of fields
			my @values;			# An array of values taken from the current record
			my $placeholders;		# A string of placeholders, eg ( ?, ?, ? )
			my $field_index = 1;		# Start at offset=1 to skip over changed flag
			
			foreach my $field ( @{$self->fieldlist} ) {
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
	
	return 1;
	
}

sub insert {
	
	my $self = shift;
	
	if ( $self->{readonly} ) {
		new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
					title   => "Read Only!",
					text    => "Datasheet is open in read-only mode!"
				       );
		return 0;
	}
		
	my $model = $self->{treeview}->get_model;
	my $iter = $model->append;
	$model->set( $iter, STATUS_COLUMN, INSERTED );
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

sub fieldlist {
	
	# This function returns a fieldlist by querying the DB server ( with the impossible condition 'where 0=1' for speed )
	# This is the only reliable way of building a fieldlist, eg when the query returned no records, or where we are inserting
	# a record, and the only field in the in-memory recordset is the primary key ( also with the possibility of an empty recordset )
	
	my $self = shift;
	
	my $sth = $self->{dbh}->prepare($self->{sql_select} . " from " . $self->{table} . " where 0=1");
	$sth->execute;
	return $sth->{'NAME'};
	
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