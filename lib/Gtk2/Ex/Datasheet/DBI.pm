#!/usr/bin/perl

# (C) Daniel Kasak: dan@entropy.homelinux.org
# See COPYRIGHT file for full license

# See 'man Gtk2::Ex::Datasheet::DBI' for full documentation ... or of course continue reading

package Gtk2::Ex::Datasheet::DBI;

use strict;
use warnings;

use Glib qw/TRUE FALSE/;

use Gtk2::Ex::Dialogs (
						destroy_with_parent	=> TRUE,
						modal				=> TRUE,
						no_separator		=> FALSE
					  );

# Record Status Indicators
use constant {
						UNCHANGED			=> 0,
						CHANGED				=> 1,
						INSERTED			=> 2,
						DELETED				=> 3
};

# Record Status column
use constant{
						STATUS_COLUMN		=> 0
};

BEGIN {
			$Gtk2::Ex::DBI::Datasheet::VERSION = '2.0';
}

sub new {
	
	my ( $class, $req ) = @_;
	
	# Assemble object from request
	my $self = {
			dbh				=> $$req{dbh},			# A database handle
			primary_key		=> $$req{primary_key},	# The primary key ( needed for inserts / updates )
			schema			=> $$req{schema},		# Database schema ( not required for MySQL )
			sql				=> $$req{sql},			# A hash of SQL related stuff
			treeview		=> $$req{treeview},		# The Gtk2::Treeview to connect to
			fields			=> $$req{fields},		# Field definitions
			multi_select	=> $$req{multi_select},	# Boolean to enable multi selection mode
			read_only		=> $$req{read_only},	# Boolean to indicate read-only mode
			on_apply		=> $$req{on_apply},		# Code that runs *after* each *record* is applied
			dump_on_error	=> $$req{dump_on_error}	# Boolean to dump SQL command on DBI error
	};
	
	bless $self, $class;
	
	my $legacy_warnings;
	
	# Reconstruct sql object if needed
	if ( $$req{sql_select} || $$req{table} || $$req{sql_where} || $$req{sql_order_by} ) {
		
		# Strip out SQL directives
		if ( $$req{sql_select} ) {
			$$req{sql_select}	=~ s/^select //i;
		}
		if ( $$req{table} ) {
			$$req{table}	=~ s/^from //i;
		}
		if ( $$req{sql_where} ) {
			$$req{sql_where}	=~ s/^where //i;
		}
		if ( $$req{sql_order_by} ) {
			$$req{sql_order_by}	=~ s/^order by //i;
		}
		
		# Assemble things
		my $sql = {
					select		=> $$req{sql_select},
					from		=> $$req{table},
					where		=> $$req{sql_where},
					order_by	=> $$req{sql_order_by}
		};
		
		$self->{sql} = $sql;
		
		$legacy_warnings = " - use the new sql object for the SQL string\n";
		
	}
	
	if ( $legacy_warnings || $self->{legacy_mode} ) {
		print "\n\n **** Gtk2::Ex::Datasheet::DBI starting in legacy mode ***\n";
		print "While quite some effort has gone into supporting this, it would be wise to take action now.\n";
		print "Warnings triggered by your request:\n$legacy_warnings\n";
	}
	
	$self->setup_treeview;
	
	# Remember the primary key column
	$self->{primary_key_column} = scalar( @{$self->{fieldlist}} ) + 1 + ( $self->{dynamic_models} || 0 );
	
	# Check recordset status when window is destroyed
	my $parent_widget = $self->{treeview}->get_parent;
	my $toplevel_widget;
	
	# Climb up through the widget heirarchy to find the toplevel widget ( the window )
	while ( $parent_widget ) {
		$toplevel_widget = $parent_widget;
		$parent_widget = $toplevel_widget->get_parent;
	}
	
	push @{$self->{objects_and_signals}},
	[
		$toplevel_widget,
		$toplevel_widget->signal_connect( delete_event => sub {
			if ( ! $self->{read_only} && $self->any_changes ) {
				my $answer = Gtk2::Ex::Dialogs::Question->new_and_run(
					title	=> "Apply changes to " . $self->{from} . " before closing?",
					text	=> "There are changes to the current datasheet ( " . $self->{from} . " )\n"
						. "that haven't yet been applied. Would you like to apply them before closing the form?"
				);
				# We return FALSE to allow the default signal handler to
				# continue with destroying the window - all we wanted to do was check
				# whether to apply records or not
				if ( $answer ) {
					if ( $self->apply ) {
						return FALSE;
					} else {
						# ie don't allow the form to close if there was an error applying
						return TRUE;
					}
				} else {
					return FALSE;
				}
			}
		} )
	];
	
	$self->query;
	
	return $self;
	
}

sub destroy_signal_handlers {
	
	my $self = shift;
	
	foreach my $set ( @{$self->{objects_and_signals}} ) {
		$$set[0]->signal_handler_disconnect( $$set[1] );
	}
	
	if ( $self->{changed_signal} ) {
		$self->{treeview}->get_model->signal_handler_disconnect( $self->{changed_signal} );
	}
	
	return TRUE;
	
}

sub destroy_self {
	
	undef $_[0];
	
}

sub destroy {
	
	my $self = shift;
	
	$self->destroy_signal_handlers;
	$self->destroy_self;
	
}

sub setup_treeview {
	
	# This sub sets up the TreeView, *and* a definition for the TreeStore ( which is used to create
	# a new TreeStore whenever we requery )
	
	my $self = shift;
	
	# Cache the fieldlist array so we don't have to continually query the DB server for it
	my $sth;
	
	my $sql = "select " . $self->{sql}->{select} . " from " . $self->{sql}->{from} . " where 0=1";
	
	eval {
		$sth = $self->{dbh}->prepare( $sql )
			|| die $self->{dbh}->errstr;
	};
	
	if ($@) {
		Gtk2::Ex::Dialogs::ErrorMsg->new_and_run(
								title		=> "Error in Query!",
								text		=> "Database server says:\n$@"
							);
		if ( $self->{dump_on_error} ) {
			print "SQL was:\n\n$sql\n\n";
		}
		return FALSE;
	}
	
	eval {
		$sth->execute || die $self->{dbh}->errstr;
	};
	
	if ($@) {
		Gtk2::Ex::Dialogs::ErrorMsg->new_and_run(
								title		=> "Error in Query!",
								text		=> "Database server says:\n$@"
							);
		if ( $self->{dump_on_error} ) {
			print "SQL was:\n\n$sql\n\n";
		}
		return FALSE;
	}
	
	$self->{fieldlist} = $sth->{'NAME'};
	
	$sth->finish;
		
	# Fetch column_info for current table
	eval {
		$sth = $self->{dbh}->column_info ( undef, $self->{schema}, $self->{sql}->{from}, '%' )
			|| die $self->{dbh}->errstr;
	};
	
	if ($@) {
		
		# We don't really want a dialog error message in this case. Dump a warning to the console
		# that we can't get column info, and continue ( renderers will default to text )
		warn "\nCould\'t get column info from database ...\n"
			. " ... This will happen in a multi-table query ...\n"
			. " ... Defaulting to text renderers for undefined fields\n\n";
		
		if ( ! $self->{primary_key} ) {
			warn "\nMISSING primary_key definition!\n"
				. "If column_info fails ( eg multi-table queries ), then you MUST\n"
				. "provide a primary_key in the constructor!\n\n";
			return FALSE;
		}
		
	} else {
		
		while ( my $column_info_row = $sth->fetchrow_hashref ) {
			# Set the primary key if we find one ( MySQL only at present )
			# but only if one hasn't been defined yet ( could be a multi-table query )
			if (
				! $self->{primary_key} && (
				$column_info_row->{mysql_is_pri_key} ||		# mysql
				$column_info_row->{TYPE_NAME} =~/ identity/	# SQL Server and maybe others
										  )
			   )
			{
				$self->{primary_key} = $column_info_row->{COLUMN_NAME};
			}
			# Loop through the list of columns from the database, and
			# add only columns that we're actually dealing with
			for my $field ( @{$self->{fieldlist}} ) {
				if ( $column_info_row->{COLUMN_NAME} eq $field ) {
					$self->{column_info}->{$field} = $column_info_row;
					last;
				}
			}
		}
		
		$sth->finish;
		
	}
	
	# If there are no field definitions, then create some from our fieldlist from the database
	if ( ! $self->{fields} ) {
		for my $field ( @{$self->{fieldlist}} ) {
			push @{$self->{fields}}, { name	=> $field };
		}
	}
	
	# Now loop through our field definitions, and fill in the renderers if they're not already done
	for my $field ( @{$self->{fields}} ) {
		if ( ! $field->{renderer} ) {
			my $sql_name = $self->column_name_to_sql_name( $field->{name} );
			my $fieldtype = $self->{column_info}->{$sql_name}->{TYPE_NAME};
			if ( $fieldtype =~ m/INT/ ) {
				$field->{renderer} = "number";
			} elsif ( $fieldtype =~ m/CHAR/ ) {
				$field->{renderer} = "text";
			} elsif ( $fieldtype eq "TIMESTAMP" || $fieldtype eq "DATE" ) {
				$field->{renderer} = "date";
			} elsif ( $fieldtype eq "TIME" ) {
				$field->{renderer} = "time";
			} else {
				$field->{renderer} = "text";
			}
		}
	}
	
	my $column_no = 0;
	
	# First is the record status indicator: a CellRendererPixbuf ...
	my $renderer = Gtk2::CellRendererPixbuf->new;
	$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes("", $renderer);
	$self->{treeview}->append_column($self->{columns}[$column_no]);
	
	# Set up fixed size for status indicator and add to sum of fixed sizes
	$self->{columns}[$column_no]->set_sizing("fixed");
	my $column_width = 20;
	
	# Hide status indicator if read-only
	if ( $self->{read_only} ) {
		$column_width = 0;
	}
	
	$self->{columns}[$column_no]->set_fixed_width( $column_width );
	$self->{sum_absolute_x} = $column_width;
	
	$self->{columns}[$column_no]->set_cell_data_func( $renderer, sub { $self->render_pixbuf_cell( @_ ); } );
	
	# ... and the TreeStore column that goes with it
	push @{$self->{ts_def}}, "Glib::Int";
	
	$column_no ++;
	
	# Now set up the model and columns
	for my $field ( @{$self->{fields}} ) {
		
		# Rename 'none' renderer to 'hidden' ... support legacy software using the old term
		if ( $field->{renderer} eq "none" ) {
			$field->{renderer} = "hidden";
		}
		
		$field->{column} = $column_no - 1; # The field number is 1 off the column number ( status column )
		
		if ( $field->{renderer} eq "text" || $field->{renderer} eq "hidden"
			|| $field->{renderer} eq "number" ) {
			
			if ( $field->{renderer} eq "hidden" ) {
				$renderer = Gtk2::CellRendererText->new; # No need for custom one if it's not being displayed
			} else {
				$renderer = MOFO::CellRendererText->new;
			}
			
			$renderer->{column} = $column_no;
			
			if ( ! $self->{read_only} ) {
				$renderer->set( editable => TRUE );
			}
			
			$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes(
																						$field->{name},
																						$renderer,
																						'text'	=> $column_no
																					);
			
			if ( $field->{renderer} eq "hidden" ) {
				$self->{columns}[$column_no]->set_visible( FALSE );
			}
			
			push @{$self->{objects_and_signals}},
			[
				$renderer,
				$renderer->signal_connect( edited => sub { $self->process_text_editing( @_ ); } )
			];
			
			$self->{treeview}->append_column($self->{columns}[$column_no]);
			
			# Add a string column to the TreeStore definition ( recreated when we query() )
			push @{$self->{ts_def}}, "Glib::String";
			
		#} elsif ( $field->{renderer} eq "number" ) {
		#	
		#	$renderer = MOFO::CellRendererSpinButton->new;
		#	
		#	if ( ! $self->{readonly} ) {
		#		$renderer->set( mode => "editable" );
		#	}
		#	
		#	$renderer->set(
		#			min	=> $field->{min}	|| 0,
		#			max	=> $field->{max}	|| 9999,
		#			digits	=> $field->{digits}	|| 0,
		#			step	=> $field->{step}	|| 1
		#		      );
		#	
		#	$renderer->{column} = $column_no;
		#	
		#	$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes(
		#											$field->{name},
		#											$renderer,
		#											'value'	=> $column_no
		#										);
		#
		#   * * * TODO * * * add to $self->{objects_and_signals} if re-activated * * * TODO * * *
		#
		#	$renderer->signal_connect( edited => sub { $self->process_text_editing( @_ ); } );
		#	
		#	$self->{treeview}->append_column($self->{columns}[$column_no]);
		#	
		#	# Add a numeric field to the TreeStore definition ( recreated when we query() )
		#	push @{$self->{ts_def}}, "Glib::Double";
			
		} elsif ( $field->{renderer} eq "combo" ) {
			
			$renderer = Gtk2::CellRendererCombo->new;
			$renderer->{column} = $column_no;
			
			# Get the data type and attach it to the renderer, so we know what kind of comparison
			# ( string vs numeric ) to use later
			my $sql_name = $self->column_name_to_sql_name( $field->{name} );
			my $fieldtype = $self->{column_info}->{$sql_name}->{TYPE_NAME};
			
			if ( $fieldtype =~ m/INT/ ) {
				$renderer->{data_type} = "numeric";
			} else {
				$renderer->{data_type} = "string";
			}
			
			if ( ! $self->{read_only} ) {
				
				$renderer->set(
								editable	=> TRUE,
								text_column	=> 1,
								has_entry	=> TRUE
							  );
				
				# It's possible that we won't have a model at this point
				if ( $field->{model} ) {
					$renderer->set( model	=> $field->{model} );
				}
				
			}
			
			$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes(
													$field->{name},
													$renderer,
													text	=> $column_no
												);
			
			push @{$self->{objects_and_signals}},
			[
				$renderer,
				$renderer->signal_connect( edited => sub { $self->process_text_editing( @_ ); } )
			];
			
			$self->{treeview}->append_column($self->{columns}[$column_no]);
			
			$self->{columns}[$column_no]->set_cell_data_func($renderer, sub { $self->render_combo_cell( @_ ); } );
			
			# Add a string column to the TreeStore definition ( recreated when we query() )
			push @{$self->{ts_def}}, "Glib::String";
			
		} elsif ( $field->{renderer} eq "dynamic_combo" ) {
			
			$renderer = Gtk2::CellRendererCombo->new;
			$renderer->{column} = $column_no;
			
			# For a dynamic combo, we have to tell the TreeViewColumn where the model is.
			# Therefore we need to keep track of how many models we've got.
			# We can't use $self->column_from_name() because this only works for columns that have a matching
			# field in our SQL command ( ie are in $self->{fieldlist} ). We also have to be careful not to
			# upset the order of columns in $self->column_from_name and $self->{fieldlist} ... ie we should
			# append these models at the end of the the main model, just before the primary key
			
			$self->{dynamic_models} ++;
			$renderer->{dynamic_model_no} = $self->{dynamic_models};
			$renderer->{dynamic_model_position} = scalar @{$self->{fieldlist}} + 1 + $self->{dynamic_model_no};
			
			# Keep this position number in the field has as well
			$field->{dynamic_model_position} = $renderer->{dynamic_model_position};
			
			if ( ! $self->{read_only} ) {
				$renderer->set(
								editable	=> TRUE,
								text_column	=> 1,
								has_entry	=> TRUE
							  );
			}
			
			# Get the data type and attach it to the renderer, so we know what kind of comparison
			# ( string vs numeric ) to use later
			my $sql_name = $self->column_name_to_sql_name( $field->{name} );
			my $fieldtype = $self->{column_info}->{$sql_name}->{TYPE_NAME};
			
			if ( $fieldtype =~ m/INT/ ) {
				$renderer->{data_type} = "numeric";
			} else {
				$renderer->{data_type} = "string";
			}
			
			$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes(
													$field->{name},
													$renderer,
													text	=> $column_no,
													model	=> $renderer->{dynamic_model_position}
												);
			
			push @{$self->{objects_and_signals}},
			[
				$renderer,
				$renderer->signal_connect( edited => sub { $self->process_text_editing( @_ ); } )
			];
			
			$self->{treeview}->append_column($self->{columns}[$column_no]);
			
			$self->{columns}[$column_no]->set_cell_data_func($renderer, sub { $self->render_combo_cell( @_ ); } );
			
			# Add a string column to the TreeStore definition ( recreated when we query() )
			push @{$self->{ts_def}}, "Glib::String";
			
			# Add a Gtk2::ListStore column to the TreeStore definition for the model of this combo,
			# ***BUT*** we can't add it here - queue it until the end of the 'normal' columns ( in the SQL select )
			push @{$self->{ts_models}}, "Gtk2::ListStore";
			
		} elsif ( $field->{renderer} eq "toggle" ) {
			
			$renderer = Gtk2::CellRendererToggle->new;
			
			if ( ! $self->{read_only} ) {
				$renderer->set( activatable	=> TRUE );
			}
			
			$renderer->{column} = $column_no;
			
			$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes(
													$field->{name},
													$renderer,
													active	=> $column_no
												);
			
			push @{$self->{objects_and_signals}},
			[
				$renderer,
				$renderer->signal_connect( toggled => sub { $self->process_toggle( @_ ); } )
			];
			
			$self->{treeview}->append_column($self->{columns}[$column_no]);
			
			# Add an integer column to the TreeStore definition ( recreated when we query() )
			push @{$self->{ts_def}}, "Glib::Boolean";
			
		} elsif ( $field->{renderer} eq "date" ) {
			
			$renderer = MOFO::CellRendererDate->new;
			$renderer->{column} = $column_no;
			
			if ( ! $self->{read_only} ) {
				$renderer->set( mode => "editable" );
			}
			
			$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes(
													$field->{name},
													$renderer,
													'date'	=> $column_no
												);
			
			push @{$self->{objects_and_signals}},
			[
				$renderer,
				$renderer->signal_connect( edited => sub { $self->process_text_editing( @_ ); } )
			];
			
			$self->{treeview}->append_column($self->{columns}[$column_no]);
			
			# Add a string column to the TreeStore definition ( recreated when we query() )
			push @{$self->{ts_def}}, "Glib::String";
			
		} elsif ( $field->{renderer} eq "time" ) {
			
			$renderer = MOFO::CellRendererTime->new;
			$renderer->{column} = $column_no;
			
			if ( ! $self->{read_only} ) {
				$renderer->set( mode => "editable" );
			}
			
			$self->{columns}[$column_no] = Gtk2::TreeViewColumn->new_with_attributes(
													$field->{name},
													$renderer,
													'time'	=> $column_no
												);
			
			push @{$self->{objects_and_renderers}},
			[
				$renderer,
				$renderer->signal_connect( edited => sub { $self->process_text_editing( @_ ); } )
			];
			
			$self->{treeview}->append_column($self->{columns}[$column_no]);
			
			# Add a string column to the TreeStore definition ( recreated when we query() )
			push @{$self->{ts_def}}, "Glib::String";
			
		} else {
			
			warn "Unknown render: " . $field->{renderer} . "\n";
			
		}
		
		# Set up column sizing stuff
		if ( $field->{x_absolute} || $field->{x_percent} ) {
			$self->{columns}[$column_no]->set_sizing("fixed");
		}
		
		# Add any absolute x values to our total and set their column size ( once only for these )
		if ( $field->{x_absolute} ) {
			$self->{sum_absolute_x} += $field->{x_absolute};
			$self->{columns}[$column_no]->set_fixed_width($field->{x_absolute});
		}
		
		# Set up static colouring
		if ( $field->{foreground_colour} ) {
			$renderer->set( foreground		=> $field->{foreground_colour} );
			$renderer->set( foreground_set	=> TRUE );
		}
		
		$column_no ++;
		
	}
	
	# Now we've finished the 'normal' columns, we can add any queued dynamic model definitions
	for my $model_def ( @{$self->{ts_models}} ) {
		push @{$self->{ts_def}}, $model_def;
	}
	
	# Now that all the columns are set up, loop over them again looking for dynamic models, so we can
	# set up automatic requerying of models when a column they depend on changes. We *could* have done this
	# in the above loop, but there's a ( remote ) chance that someone will want to set up a dynamic combo
	# that depends on a column *after* it ... while I can't see why people would do this, it's easy relatively
	# easy to accomodate anyway.
	
	for my $field ( @{$self->{fields}} ) {
		if ( $field->{renderer} && $field->{renderer} eq "dynamic_combo" ) {
			for my $criteria ( @{$field->{model_setup}->{criteria}} ) {
				push @{($self->{columns}[$self->column_from_name($criteria->{column_name})]->get_cell_renderers)[0]->{dependant_columns}},
					$field->{column};
			}
		}
	}
	
	# Finally, a column for the primary key to the TreeStore definition ... *MUST* have a numberic primary key
	push @{$self->{ts_def}}, "Glib::Int";
	
	# Now set up icons for use in the record status column
	$self->{icons}[UNCHANGED]	= $self->{treeview}->render_icon( "gtk-yes",		"menu" );
	$self->{icons}[CHANGED]		= $self->{treeview}->render_icon( "gtk-refresh",	"menu" );
	$self->{icons}[INSERTED]	= $self->{treeview}->render_icon( "gtk-add",		"menu" );
	$self->{icons}[DELETED]		= $self->{treeview}->render_icon( "gtk-delete",		"menu" );
	
	$self->{resize_signal} = $self->{treeview}->signal_connect( size_allocate => sub { $self->size_allocate( @_ ); } );
	
	push @{$self->{objects_and_signals}},
	[
		$self->{treeview},
		$self->{resize_signal}
	];
	
	# Turn on multi-select mode if requested
	if ($self->{multi_select}) {
		$self->{treeview}->get_selection->set_mode("multiple");
	}
	
	$self->{current_width} = 0; # Prevent warnings
	
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
	
	if ( $combo_model ) {
		
		# Loop through our combo's model and find a match for the above ID to get our text value
		my $combo_iter = $combo_model->get_iter_first;
		my $found_match = FALSE;
		
		while ($combo_iter) {
			
			if ( $renderer->{data_type} eq "numeric" ) {
				if (
						$combo_model->get( $combo_iter, 0 )
							&& $key_value
							&& $combo_model->get( $combo_iter, 0 ) == $key_value
				   )
				{
					$found_match = TRUE;
					$renderer->set( text	=> $combo_model->get( $combo_iter, 1 ) );
					last;
				}
			} else {
				if (
						$combo_model->get( $combo_iter, 0 )
							&& $key_value
							&& $combo_model->get( $combo_iter, 0 ) eq $key_value
				   )
				{
					$found_match = TRUE;
					$renderer->set( text	=> $combo_model->get( $combo_iter, 1 ) );
					last;
				}
			}
			
			$combo_iter = $combo_model->iter_next($combo_iter);
			
		}
		
		# If we haven't found a match, default to displaying an empty value
		if ( !$found_match ) {
			$renderer->set( text	=> "" );
		}
		
	} else {
		
		print "Gtk2::Ex::Datasheet::DBI::render_combo_cell called without a model being attached!\n";
		
	}
	
	return FALSE;
	
}

sub refresh_dynamic_combos {

	# If this column has dependant cells ...
	# ( ie dynamic combos - in this case *this* renderer will have an array of
	# dependant_columns pointing to the *dependant* columns )
	#  ... refresh them
	
	my ( $self, $renderer, $path ) = @_;
	
	my $model = $self->{treeview}->get_model;
	my $iter = $model->get_iter ($path); # I've been told not to pass iters around, so we'd better get a fresh one
	
	if ( $renderer->{dependant_columns} ) {
		
		# Get the current row in an array
		my @data = $model->get( $model->get_iter( $path ) );
		
		# We don't want the status column in there - it's not in the SQL fieldlist
		my $status = shift( @data );
		
		for my $dependant ( @{$renderer->{dependant_columns}} ) {
			
			# Create a new model
			my $new_model = $self->create_dynamic_model(
															$self->{fields}[$dependant]->{model_setup},
															\@data
													   );
			
			# Dump the combo model in the main TreeView model
			$model->set(
					$iter,
					$self->{fields}[$dependant]->{dynamic_model_position},
					$new_model
				   );
			
		}
		
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
		
		my $combo_model;
		
		# If this is a dynamic combo, we can't get the model simply by $render->get("model") because
		# this is unreliable if the user has clicked outside the current row to end editing.
		if ( $renderer->{dynamic_model_position} ) {
			$combo_model = $model->get( $iter, $renderer->{dynamic_model_position} );
		} else {
			$combo_model = $renderer->get("model");
		}
		
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
        
		# Refresh dependant columns if any
		if ( $renderer->{dependant_columns} ) {
			$self->refresh_dynamic_combos( $renderer, $path );
		}
		
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
	
	# Refresh dependant columns if any
	if ( $renderer->{dependant_columns} ) {
		$self->refresh_dynamic_combos( $renderer, $path );
	}
	
	return FALSE;
	
}

sub query {
	
	my ( $self, $where_object, $dont_apply ) = @_;
	
	my $model = $self->{treeview}->get_model;
	
	if ( ! $dont_apply && $model ) {
		
		# First test to see if we have any outstanding changes to the current datasheet
		
		my $iter = $model->get_iter_first;
		
		while ($iter) {
			
			my $status = $model->get($iter, STATUS_COLUMN);
			
			# Decide what to do based on status
			if ( $status != UNCHANGED ) {
				
				my $answer = ask Gtk2::Ex::Dialogs::Question(
						    title	=> "Apply changes to " . $self->{sql}->{from} . " before querying?",
						    text	=> "There are outstanding changes to the current datasheet ( " . $self->{sql}->{from} . " )."
									. " Do you want to apply them before running a new query?"
									    );
				
				if ( $answer ) {
				    if ( ! $self->apply ) {
						return FALSE; # Apply method will already give a dialog explaining error
				    }
				}
				
			}
			
			$iter = $model->iter_next($iter);
			
		}
		
	}
	
	# Deal with legacy mode - the query method used to accept an optional where clause
	if ( $where_object ) {
		
		if ( ref( $where_object ) ne "HASH" ) {
			
			# Legacy mode
			# Strip 'where ' out of clause
			$where_object =~ s/^where //i;
			
			# Transfer new where clause if defined
			$self->{sql}->{where} = $where_object;
			
			# Also remove any bound values if called in legacy mode
			$self->{sql}->{bind_values} = undef;
			
		} else {
			
			# NOT legacy mode
			if ( $where_object->{where} ) {
				$self->{sql}->{where} = $where_object->{where};
			}
			if ( $where_object->{bind_values} ) {
				$self->{sql}->{bind_values} = $where_object->{bind_values};
			}
			
		}
		
	}
	
	my $sql = "select " . $self->{sql}->{select} . ", " . $self->{primary_key} . " from " . $self->{sql}->{from};
	
	if ( $self->{sql}->{where} ) {
		$sql .= " where " . $self->{sql}->{where};
	}
	
	if ( $self->{sql}->{order_by} ) {
		$sql .= " order by " . $self->{sql}->{order_by};
	}
	
	my $sth;
	
	eval {
		$sth = $self->{dbh}->prepare( $sql ) || die;
	};
	
	if ($@) {
		new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
			title   => "Error preparing select statement!",
			text    => "Database Server says:\n" . $self->{dbh}->errstr
		);
		if ( $self->{dump_on_error} ) {
			print "SQL was:\n\n$sql\n\n";
		}
		return FALSE;
	}
	
	# Create a new ListStore
	my $liststore = Gtk2::ListStore->new(@{$self->{ts_def}});
	
	eval {
		if ( $self->{sql}->{bind_values} ) {
			$sth->execute( @{$self->{sql}->{bind_values}} ) || die $self->{dbh}->errstr;
		} else {
			$sth->execute || die $self->{dbh}->errstr;
		}
	};
	
	if ($@) {
		new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
			title   => "Error executing statement!",
			text    => "Database Server says:\n" . $self->{dbh}->errstr
		);
		if ( $self->{dump_on_error} ) {
			print "SQL was:\n\n$sql\n\n";
		}
		return FALSE;
	}
	
	while (my @row = $sth->fetchrow_array) {
		
		my @model_row;
		my @dynamic_models;
		my $column = 0;
		
		# Append a new treeiter, and the status indicator
		push @model_row, $liststore->append, STATUS_COLUMN, UNCHANGED;
		
		for my $field (@{$self->{fields}}) {
			
			push @model_row,
				$column + 1,
				$row[$column];
			
			# If this is a dynamic combo, append it to the end of the 'normal' columns
			# Luckily we have already figured out it's position ...
			if ( $field->{renderer} && $field->{renderer} eq "dynamic_combo" ) {
				push @model_row,
					$field->{dynamic_model_position},
					$self->create_dynamic_model( $field->{model_setup}, \@row );
			}
						
			$column++;
		}
		
		# Append queued models for dynamic combos
		#for my $dynamic_model ( @dynamic_models ) {
		#	push @model_row, $dynamic_model;
		#}
		
		# Append the primary key to the end
		push @model_row,
			$column + 1 + ( $self->{dynamic_models} || 0 ),
			$row[$column];
		
		$liststore->set( @model_row );
		
	}
	
	# Destroy changed_signal attached to old model
	if ( $self->{changed_signal} ) {
		$self->{treeview}->get_model->signal_handler_disconnect( $self->{changed_signal} );
	}
	
	$self->{changed_signal} = $liststore->signal_connect( "row-changed" => sub { $self->changed(@_) } );
	
	$self->{treeview}->set_model( $liststore );
	
}

sub undo {
	
	# undo and revert are synonyms of each other
	
	my $self = shift;
	
	$self->query( undef, TRUE );
	
}

sub revert {
	
	# undo and revert are synonyms of each other
	
	my $self = shift;
	
	$self->query( undef, TRUE );
	
}

sub changed {
	
	my ( $self, $liststore, $treepath, $iter ) = @_;
	
	my $model = $self->{treeview}->get_model;
	
	# Only change the record status if it's currently unchanged
	if ( ! $model->get( $iter, STATUS_COLUMN ) ) {
		$model->signal_handler_block( $self->{changed_signal} );
		$model->set( $iter, STATUS_COLUMN, CHANGED );
		$model->signal_handler_unblock( $self->{changed_signal} );
	}
	
}

sub apply {
	
	my $self = shift;
	
	if ( $self->{readonly} ) {
		new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
					title   => "Read Only!",
					text    => "Datasheet is open in read-only mode!"
				       );
		return FALSE;
	}
	
	my $model = $self->{treeview}->get_model;
	my $iter = $model->get_iter_first;
	
	while ($iter) {
		
		my $status = $model->get( $iter, STATUS_COLUMN );
		
		# Decide what to do based on status
		if ( $status == UNCHANGED ) {
			
			$iter = $model->iter_next( $iter );
			next;
			
		} elsif ( $status == DELETED ) {
			
			my $primary_key = $model->get( $iter, $self->{primary_key_column} );
			
			my $sql = "delete from " . $self->{sql}->{from} . " where " . $self->{primary_key} . "=?";
			
			my $sth = $self->{dbh}->prepare( $sql );
			
			eval {
				$sth->execute( $primary_key ) || die;
			};
			
			if ($@) {
				new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
					title   => "Error deleting record!",
					text    => "Database Server says:\n" . $self->{dbh}->errstr
				);
				if ( $self->{dump_on_error} ) {
					print "SQL was:\n\n$sql\n\n";
				}
				return FALSE;
			};
			
			$model->remove( $iter );
			
		} else {
			
			# We process the insert / update operations in a similar fashion
			
			my $sql;					# Final SQL to send to DB server
			my $sql_fields;				# A comma-separated list of fields
			my @values;					# An array of values taken from the current record
			my $placeholders;			# A string of placeholders, eg ( ?, ?, ? )
			my $field_index = 1;		# Start at offset=1 to skip over changed flag
			my $primary_key = undef;	# We pass this to the on_apply() function
			
			foreach my $field ( @{$self->{fieldlist}} ) {
				if ( $status == INSERTED ) {
					$sql_fields .= " $field,";
					$placeholders .= " ?,";
				} else {
					$sql_fields .= " $field=?,";
				}
				push @values, $model->get( $iter, $field_index );
				$field_index++;
			}
			
			# Remove trailing comma
			chop($sql_fields);
			
			if ( $status == INSERTED ) {
				chop($placeholders);
				$sql = "insert into " . $self->{sql}->{from} . " ( $sql_fields ) values ( $placeholders )";
			} else {
				$sql = "update " . $self->{sql}->{from} . " set $sql_fields"
					. " where " . $self->{primary_key} . "=?";
				$primary_key = $model->get( $iter, $self->{primary_key_column} );
				push @values, $primary_key;
			}
			
			my $sth;
			
			eval {
				$sth = $self->{dbh}->prepare( $sql ) || die;
			};
			
			if ($@) {
				new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
					title   => "Error preparing statement!",
					text    => "Database Server says:\n" . $self->{dbh}->errstr
				);
				if ( $self->{dump_on_error} ) {
					print "SQL was:\n\n$sql\n\n";
				}
				return FALSE;
			}
			
			eval {
				$sth->execute(@values) || die;
			};
			
			if ($@) {
				new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
					title   => "Error processing recordset!",
					text    => "Database Server says:\n" . $self->{dbh}->errstr
				);
				if ( $self->{dump_on_error} ) {
					print "SQL was:\n\n$sql\n\n";
				}
				return FALSE;
			}
			
			# If we just inserted a record, we have to fetch the primary key and replace the current '!' with it
			if ( $status == INSERTED ) {
				$primary_key = $self->last_insert_id;
				$model->set( $iter, $self->{primary_key_column}, $primary_key );
			}
			
			# If we've gotten this far, the update was OK, so we'll reset the 'changed' flag
			# and move onto the next record
			$model->signal_handler_block( $self->{changed_signal} );
			$model->set( $iter, STATUS_COLUMN, UNCHANGED );
			$model->signal_handler_unblock( $self->{changed_signal} );
			
			# Execute user-defined functions
			if ( $self->{on_apply} ) {
				
				# Better change the status indicator back into text, rather than make
				# people use our constants. I think, anyway ...
				my $status_txt;
				
				if ( $status		== INSERTED ) {
					$status_txt		= "inserted";
				} elsif ( $status	== CHANGED ) {
					$status_txt		= "changed";
				} elsif ( $status	== DELETED ) {
					$status_txt		= "deleted";
				}
				
				# Do people want the whole row? I don't. Maybe others would? Wait for requests...
				$self->{on_apply}(
						  {
							status		=> $status_txt,
							primary_key	=> $primary_key,
						  }
						 );
				
			}
			
		}
		
		$iter = $model->iter_next( $iter );
		
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
	
	# Append any remaining fields ( ie that haven't been explicitely defined in @columns_and_values )
	# with default values from the database to the @columns_and_values array
	
	for my $column_no ( 0 .. @{$self->{fieldlist}} - 1) {
		my $found = FALSE;
		for ( my $x = 0; $x < ( scalar(@columns_and_values) / 2 ); $x ++ ) {
			if ( $columns_and_values[ ( $x * 2 ) ] - 1 == $column_no ) { # The array is 2 wide, plus 1 for status
				$found = TRUE;
				last;
			}
		}
		if ( ! $found ) {
			push
				@columns_and_values,
				$column_no + 1, # Add 1 for status
				$self->{column_info}->{$self->{fieldlist}[$column_no]}->{COLUMN_DEF};
		}
	}
	
	my @new_record;
	
	push @new_record, $iter, STATUS_COLUMN, INSERTED;
	
	if ( scalar(@columns_and_values) ) {
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
		$self->{treeview}->signal_handler_unblock( $self->{resize_signal} );
		
	}
	
}

sub column_from_name {
	
	# This function takes an *SQL* field name and returns the column that the field is in by
	# walking through the array $self->{fieldlist}
	
	# It returns the column no in the MODEL
	
	my ( $self, $sql_fieldname ) = @_;
	
	my $counter = 1; # Start at 1, because column 0 is status column
	
	for my $field ( @{$self->{fieldlist}} ) {
		if ( $field eq $sql_fieldname ) {
			return $counter;
		}
		$counter ++;
	}
	
}

sub column_from_column_name {
	
	# This function takes a *COLUMN* name and returns the column that the field is in by
	# walking through the array $self->{fields}
	
	# It returns the column no in the MODEL
	
	my ( $self, $column_name ) = @_;
	
	my $counter = 1; # Start at 1, because column 0 is a status column
	
	for my $field ( @{$self->{fields}} ) {
		if ( $field->{name} eq $column_name ) {
			return $counter;
		}
		$counter ++;
	}
	
}

sub column_name_to_sql_name {
	
	# This function converts a column name to an SQL field name
	
	my ( $ self, $column_name ) = @_;
	
	my $column_no = $self->column_from_column_name ( $column_name );
	return $self->{fieldlist}[$column_no - 1]; # minus 1 as $self->{fieldlist} doesn't have a status 'column'
	
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

sub replace_combo_model {
	
	# This function replaces a *normal* combo ( NOT a dynamic one ) with a new one
	
	my ( $self, $column_no, $model ) = @_;
	
	my $column = $self->{treeview}->get_column($column_no);
	my $renderer = ($column->get_cell_renderers)[0];
	$renderer->set( model => $model );
	
	return TRUE;
	
}

sub create_dynamic_model {
	
	# This function accepts a combo definition and a row of data ( *MINUS* the record status column ),
	# and creates a combo model to insert back into the main TreeView's model
	# We currently only support a model with 2 columns: an ID column and a Display column
	
	# *** TODO *** support adding more columns to the model
	
	my ( $self, $model_setup, $data ) = @_;
	
	# Firstly we clone the database handle, as the DBD::ODBC / FreeTDS combo won't allow
	# multiple active statements on the same connection
	
	# *** TODO *** Test for the DBD::ODBC driver type so we don't clone the dbh unless we need to
	
	my $dbh = $self->{dbh}->clone;
	
	my $liststore = Gtk2::ListStore->new(
		"Glib::String",
		"Glib::String"
	);
	
	# Deal with legacy mode
	my $legacy_warnings;
	
	if ( $model_setup->{table} ) {
		$model_setup->{from} = $model_setup->{table};
		$legacy_warnings .= " - \$model_setup->{table} renamed to \$model_setup->{from} for consistency\n";
	}
	
	if ( $model_setup->{order_by} && $model_setup->{order_by} =~ m/^order by /i ) {
		$model_setup->{order_by} =~ s/^order by //i;
		$legacy_warnings .= " - ommit the words \'order by\' from \$model_setup->{order_by}\n";
	}
	
	if ( $model_setup->{group_by} && $model_setup->{group_by} =~ m/^group by /i ) {
		$model_setup->{group_by} =~ s/^group by //i;
		$legacy_warnings .= " - ommit the words \'order by\' from \$model_setup->{group_by}\n";
	}
	
	if ( $legacy_warnings ) {
		print "Gtk2::Ex::Datasheet::DBI::create_dynamic_model raised the following warnings:\n$legacy_warnings\n";
	}
	
	my $sql = "select " . $model_setup->{id} . ", " . $model_setup->{display} . " from " . $model_setup->{from};
	my @bind_variables;
	
	if ( $model_setup->{criteria} ) {
		$sql .= " where";
		for my $criteria ( @{$model_setup->{criteria}} ) {
			$sql .= " " . $criteria->{field} . "=? and";
			push @bind_variables, $$data[$self->column_from_name( $criteria->{column_name} ) - 1];
		}
	}
	
	$sql = substr( $sql, 0, length($sql) - 3 ); # Remove trailing 'and'
	
	if ( $model_setup->{group_by} ) {
		$sql .= " " . $model_setup->{group_by};
	}
	
	if ( $model_setup->{order_by} ) {
		$sql .= " order by " . $model_setup->{order_by};
	}
	
	my $sth;
	
	eval {
		$sth = $dbh->prepare( $sql ) || die $dbh->errstr;
	};
	
	if ($@) {
		new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
					title   => "Error creating combo model!",
					text    => "DB server says:\n$@"
		);
		if ( $self->{dump_on_error} ) {
			print "SQL was:\n\n$sql\n\n";
		}
		return FALSE;
	}
	
	$sth->execute( @bind_variables );
	
	my $iter;
    
	while (my @record = $sth->fetchrow_array) {
	    $iter = $liststore->append;
		$liststore->set(
					$iter,
					0, $record[0],
					1, $record[1]
			       );
	}
	
	$sth->finish;
	$dbh->disconnect;
	
	return $liststore;
	
}

sub any_changes {
	
	# This function loops through all records and returns TRUE if any record status is not UNCHANGED
	
	my $self = shift;
	
	my $model = $self->{treeview}->get_model;
	my $iter = $model->get_iter_first;
	
	while ($iter) {
		my $status = $model->get($iter, STATUS_COLUMN);
		if ( $status == UNCHANGED ) {
			$iter = $model->iter_next($iter);
			next;
		} else {
			return TRUE;
		}
	}
	
	return FALSE;
	
}

1;

#######################################################################################
# That's the end of Gtk2::Ex::Datasheet::DBI
# What follows is stuff I've plucked from around the place
#######################################################################################






#######################################################################################
# Custom CellRendererText
#######################################################################################

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

#######################################################################################
# CellRendererSpinButton - current non-functional and disabled :(
#######################################################################################

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
	
	my ( $cell, $event, $view, $path, $background_area, $cell_area, $flags ) = @_;
	my $spin_button = Gtk2::SpinButton -> new_with_range( $cell -> get(qw(min max step)) );
	
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


#######################################################################################
# CellRendererDate
#######################################################################################

# Copyright (C) 2003 by Torsten Schoenfeld
# 
# This library is free software; you can redistribute it and/or modify it under
# the terms of the GNU Library General Public License as published by the Free
# Software Foundation; either version 2.1 of the License, or (at your option)
# any later version.
# 
# This library is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU Library General Public License for
# more details.
# 
# You should have received a copy of the GNU Library General Public License
# along with this library; if not, write to the Free Software Foundation, Inc.,
# 59 Temple Place - Suite 330, Boston, MA  02111-1307  USA.
#
# $Header: /cvsroot/gtk2-perl/gtk2-perl-xs/Gtk2/examples/cellrenderer_date.pl,v 1.5 2005/01/07 21:31:59 kaffeetisch Exp $
#


use strict;
use Gtk2 -init;

package MOFO::CellRendererDate;

use Glib::Object::Subclass
  "Gtk2::CellRenderer",
  signals => {
    edited => {
      flags => [qw(run-last)],
      param_types => [qw(Glib::String Glib::Scalar)],
    },
  },
  properties => [
    Glib::ParamSpec -> boolean("editable", "Editable", "Can I change that?", 0, [qw(readable writable)]),
    Glib::ParamSpec -> string("date", "Date", "What's the date again?", "", [qw(readable writable)]),
  ]
;

use constant x_padding => 2;
use constant y_padding => 3;

use constant arrow_width => 15;
use constant arrow_height => 15;

sub hide_popup {
  my ($cell) = @_;

  Gtk2 -> grab_remove($cell -> { _popup });
  $cell -> { _popup } -> hide();
}

sub get_today {
  my ($cell) = @_;

  my ($day, $month, $year) = (localtime())[3, 4, 5];
  $year += 1900;
  $month += 1;

  return ($year, $month, $day);
}

sub get_date {
  my ($cell) = @_;

  my $text = $cell -> get("date");
  my ($year, $month, $day) = $text
    ? split(/[\/-]/, $text)
    : $cell -> get_today();

  return ($year, $month, $day);
}

sub add_padding {
  my ($cell, $year, $month, $day) = @_;
  return ($year, sprintf("%02d", $month), sprintf("%02d", $day));
}

sub INIT_INSTANCE {
  my ($cell) = @_;

  my $popup = Gtk2::Window -> new ('popup');
  my $vbox = Gtk2::VBox -> new(0, 0);

  my $calendar = Gtk2::Calendar -> new();

  my $hbox = Gtk2::HBox -> new(0, 0);

  my $today = Gtk2::Button -> new('Today');
  my $none = Gtk2::Button -> new('None');

  $cell -> {_arrow} = Gtk2::Arrow -> new("down", "none");

  # We can't just provide the callbacks now because they might need access to
  # cell-specific variables.  And we can't just connect the signals in
  # START_EDITING because we'd be connecting many signal handlers to the same
  # widgets.
  $today -> signal_connect(clicked => sub {
    $cell -> { _today_clicked_callback } -> (@_)
      if (exists($cell -> { _today_clicked_callback }));
  });

  $none -> signal_connect(clicked => sub {
    $cell -> { _none_clicked_callback } -> (@_)
      if (exists($cell -> { _none_clicked_callback }));
  });

  $calendar -> signal_connect(day_selected_double_click => sub {
    $cell -> { _day_selected_double_click_callback } -> (@_)
      if (exists($cell -> { _day_selected_double_click_callback }));
  });

  $calendar -> signal_connect(month_changed => sub {
    $cell -> { _month_changed } -> (@_)
      if (exists($cell -> { _month_changed }));
  });

  $hbox -> pack_start($today, 1, 1, 0);
  $hbox -> pack_start($none, 1, 1, 0);

  $vbox -> pack_start($calendar, 1, 1, 0);
  $vbox -> pack_start($hbox, 0, 0, 0);

  # Find out if the click happended outside of our window.  If so, hide it.
  # Largely copied from Planner (the former MrProject).

  # Implement via Gtk2::get_event_widget?
  $popup -> signal_connect(button_press_event => sub {
    my ($popup, $event) = @_;

    if ($event -> button() == 1) {
      my ($x, $y) = ($event -> x_root(), $event -> y_root());
      my ($xoffset, $yoffset) = $popup -> window() -> get_root_origin();

      my $allocation = $popup -> allocation();

      my $x1 = $xoffset + 2 * $allocation -> x();
      my $y1 = $yoffset + 2 * $allocation -> y();
      my $x2 = $x1 + $allocation -> width();
      my $y2 = $y1 + $allocation -> height();

      unless ($x > $x1 && $x < $x2 && $y > $y1 && $y < $y2) {
        $cell -> hide_popup();
        return 1;
      }
    }

    return 0;
  });

  $popup -> add($vbox);

  $cell -> { _popup } = $popup;
  $cell -> { _calendar } = $calendar;
}

sub START_EDITING {
  my ($cell, $event, $view, $path, $background_area, $cell_area, $flags) = @_;

  my $popup = $cell -> { _popup };
  my $calendar = $cell -> { _calendar };

  # Specify the callbacks.  Will be called by the signal handlers set up in
  # INIT_INSTANCE.
  $cell -> { _today_clicked_callback } = sub {
    my ($button) = @_;
    my ($year, $month, $day) = $cell -> get_today();

    $cell -> signal_emit(edited => $path, join("-", $cell -> add_padding($year, $month, $day)));
    $cell -> hide_popup();
  };

  $cell -> { _none_clicked_callback } = sub {
    my ($button) = @_;

    $cell -> signal_emit(edited => $path, "");
    $cell -> hide_popup();
  };

  $cell -> { _day_selected_double_click_callback } = sub {
    my ($calendar) = @_;
    my ($year, $month, $day) = $calendar -> get_date();

    $cell -> signal_emit(edited => $path, join("-", $cell -> add_padding($year, ++$month, $day)));
    $cell -> hide_popup();
  };

  $cell -> { _month_changed } = sub {
    my ($calendar) = @_;

    my ($selected_year, $selected_month) = $calendar -> get_date();
    my ($current_year, $current_month, $current_day) = $cell -> get_today();

    if ($selected_year == $current_year &&
        ++$selected_month == $current_month) {
      $calendar -> mark_day($current_day);
    }
    else {
      $calendar -> unmark_day($current_day);
    }
  };

  my ($year, $month, $day) = $cell -> get_date();

  $calendar -> select_month($month - 1, $year);
  $calendar -> select_day($day);

  # Necessary to get the correct allocation of the popup.
  $popup -> move(-500, -500);
  $popup -> show_all();
  
  # Figure out where to put the popup - ie don't put it offscreen,
  # as it's not movable ( by the user )
  my $screen_height = $popup->get_screen->get_height;
  my $requisition = $popup->size_request();
  my $popup_width = $requisition->width;
  my $popup_height = $requisition->height;
  my ($x_origin, $y_origin) =  $view -> get_bin_window() -> get_origin();
  my ($popup_x, $popup_y);
  
  $popup_x = $x_origin + $cell_area->x() + $cell_area->width() - $popup_width;
  $popup_x = 0 if $popup_x < 0;
  
  $popup_y = $y_origin + $cell_area -> y() + $cell_area -> height();
  
  if ( $popup_y + $popup_height > $screen_height ) {
	$popup_y = $y_origin + $cell_area -> y() - $popup_height;
  }
  
  $popup -> move( $popup_x, $popup_y );

  # Grab the focus and the pointer.
  Gtk2 -> grab_add($popup);
  $popup -> grab_focus();

  Gtk2::Gdk -> pointer_grab($popup -> window(),
                            1,
                            [qw(button-press-mask
                                button-release-mask
                                pointer-motion-mask)],
                            undef,
                            undef,
                            0);

  return;
}

sub get_date_string {
  my $cell = shift;
  return $cell->get ('date');
}

sub calc_size {
  my ($cell, $layout) = @_;
  my ($width, $height) = $layout -> get_pixel_size();

  return (0,
          0,
          $width + x_padding * 2 + arrow_width,
          $height + y_padding * 2);
}

sub GET_SIZE {
  my ($cell, $widget, $cell_area) = @_;

  my $layout = $cell -> get_layout($widget);
  $layout -> set_text($cell -> get_date_string());

  return $cell -> calc_size($layout);
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
  $layout -> set_text($cell -> get_date_string());

  my ($x_offset, $y_offset, $width, $height) = $cell -> calc_size($layout);

  $widget -> get_style -> paint_layout($window,
                                       $state,
                                       1,
                                       $cell_area,
                                       $widget,
                                       "cellrenderertext",
                                       $cell_area -> x() + $x_offset + x_padding,
                                       $cell_area -> y() + $y_offset + y_padding,
                                       $layout);

  $widget -> get_style -> paint_arrow ($window,
                                       $widget->state,
                                       'none',
                                       $cell_area,
                                       $cell -> { _arrow },
                                       "",
                                       "down",
                                       1,
                                       $cell_area -> x + $cell_area -> width - arrow_width,
                                       $cell_area -> y + $cell_area -> height - arrow_height - 2,
                                       arrow_width - 3,
                                       arrow_height);
}

1;

#######################################################################################
# CellRendererTime
#######################################################################################

# Copyright (C) 2005 by Daniel Kasak ...
#  ... basically a slightly modified CellRendererDate ( see above )
# 
# This library is free software; you can redistribute it and/or modify it under
# the terms of the GNU Library General Public License as published by the Free
# Software Foundation; either version 2.1 of the License, or (at your option)
# any later version.
# 
# This library is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU Library General Public License for
# more details.
# 
# You should have received a copy of the GNU Library General Public License
# along with this library; if not, write to the Free Software Foundation, Inc.,
# 59 Temple Place - Suite 330, Boston, MA  02111-1307  USA.

use strict;
use Gtk2 -init;

package MOFO::CellRendererTime;

use Glib::Object::Subclass
  "Gtk2::CellRenderer",
  signals => {
    edited => {
      flags => [qw(run-last)],
      param_types => [qw(Glib::String Glib::Scalar)],
    },
  },
  properties => [
    Glib::ParamSpec -> boolean("editable", "Editable", "Can I change that?", 0, [qw(readable writable)]),
    Glib::ParamSpec -> string("time", "Time", "What's the time again?", "", [qw(readable writable)]),
  ]
;

use constant x_padding => 2;
use constant y_padding => 3;

use constant arrow_width => 15;
use constant arrow_height => 15;

sub hide_popup {
  my ($cell) = @_;

  Gtk2 -> grab_remove($cell -> { _popup });
  $cell -> { _popup } -> hide();
}

sub get_time {
  my ($cell) = @_;

  my $text = $cell -> get("time");
  my ($h, $m, $s) = split(/:/, $text);
  
  return ($h, $m, $s);
}

sub add_padding {
  my ($cell, $h, $m, $s) = @_;
  return ( sprintf("%02d",$h), sprintf("%02d", $m), sprintf("%02d", $s) );
}

sub INIT_INSTANCE {
  my ($cell) = @_;

  my $popup = Gtk2::Window -> new ('popup');
  my $vbox = Gtk2::VBox -> new(0, 0);

  my $h_spinbutton = Gtk2::SpinButton -> new_with_range( 0, 23, 1 );
  my $m_spinbutton = Gtk2::SpinButton -> new_with_range( 0, 59, 1 );
  my $s_spinbutton = Gtk2::SpinButton -> new_with_range( 0, 59, 1 );
  my $colon_1 = Gtk2::Label->new(":");
  my $colon_2 = Gtk2::Label->new(":");
  
  my $spin_hbox = Gtk2::HBox -> new(0, 0);
  my $buttons_hbox = Gtk2::HBox->new(0, 0);
  
  $cell -> {_arrow} = Gtk2::Arrow -> new("down", "none");
  
  $spin_hbox->pack_start( $h_spinbutton,	1, 1, 0 );
  $spin_hbox->pack_start( $colon_1,			1, 1, 0 );
  $spin_hbox->pack_start( $m_spinbutton,	1, 1, 0 );
  $spin_hbox->pack_start( $colon_2,			1, 1, 0 );
  $spin_hbox->pack_start( $s_spinbutton,	1, 1, 0 );
  
  my $ok = Gtk2::Button->new_from_stock('gtk-ok');
  
  $buttons_hbox->pack_start( $ok, 1, 1, 0 );
  
  $vbox -> pack_start( $spin_hbox, 0, 0, 0 );
  $vbox->pack_start( $buttons_hbox, 0, 0, 0 );
  
  # We can't just provide the callbacks now because they might need access to
  # cell-specific variables.  And we can't just connect the signals in
  # START_EDITING because we'd be connecting many signal handlers to the same
  # widgets.
  
  $ok -> signal_connect(
	clicked => sub {
						$cell -> { _ok_clicked_callback } -> (@_)
							if ( exists( $cell -> { _ok_clicked_callback } ) );
	}
					   );
    
  # Find out if the click happended outside of our window.  If so, hide it.
  # Largely copied from Planner (the former MrProject).

  # Implement via Gtk2::get_event_widget?
  $popup -> signal_connect(button_press_event => sub {
    my ($popup, $event) = @_;

    if ($event -> button() == 1) {
      my ($x, $y) = ($event -> x_root(), $event -> y_root());
      my ($xoffset, $yoffset) = $popup -> window() -> get_root_origin();

      my $allocation = $popup -> allocation();

      my $x1 = $xoffset + 2 * $allocation -> x();
      my $y1 = $yoffset + 2 * $allocation -> y();
      my $x2 = $x1 + $allocation -> width();
      my $y2 = $y1 + $allocation -> height();

      unless ($x > $x1 && $x < $x2 && $y > $y1 && $y < $y2) {
        $cell -> hide_popup();
        return 1;
      }
    }

    return 0;
  });

  $popup -> add($vbox);

  $cell -> { _popup } = $popup;
  $cell -> { _h_spinbutton } = $h_spinbutton;
  $cell -> { _m_spinbutton } = $m_spinbutton;
  $cell -> { _s_spinbutton } = $s_spinbutton;
  
}

sub START_EDITING {
  my ($cell, $event, $view, $path, $background_area, $cell_area, $flags) = @_;

  my $popup = $cell -> { _popup };
  my $h_spinbutton = $cell -> { _h_spinbutton };
  my $m_spinbutton = $cell -> { _m_spinbutton };
  my $s_spinbutton = $cell -> { _s_spinbutton };
  
  my ($h, $m, $s) = $cell -> get_time();
  
  $h_spinbutton->set_text($h);
  $m_spinbutton->set_text($m);
  $s_spinbutton->set_text($s);
  
  $cell -> { _ok_clicked_callback } = sub {
    
	my ( $button ) = @_;
	my $h = $h_spinbutton->get_text;
	my $m = $m_spinbutton->get_text;
	my $s = $s_spinbutton->get_text;
	
	$cell -> signal_emit(
							edited => $path,
							join( ":", $cell -> add_padding($h, $m, $s ) )
						);
	
	$cell -> hide_popup();
  };
  
  # Necessary to get the correct allocation of the popup.
  $popup -> move(-500, -500);
  $popup -> show_all();
  
  # Figure out where to put the popup - ie don't put it offscreen,
  # as it's not movable ( by the user )
  my $screen_height = $popup->get_screen->get_height;
  my $requisition = $popup->size_request();
  my $popup_width = $requisition->width;
  my $popup_height = $requisition->height;
  my ($x_origin, $y_origin) =  $view -> get_bin_window() -> get_origin();
  my ($popup_x, $popup_y);
  
  $popup_x = $x_origin + $cell_area->x() + $cell_area->width() - $popup_width;
  $popup_x = 0 if $popup_x < 0;
  
  $popup_y = $y_origin + $cell_area -> y() + $cell_area -> height();
  
  if ( $popup_y + $popup_height > $screen_height ) {
	$popup_y = $y_origin + $cell_area -> y() - $popup_height;
  }
  
  $popup -> move( $popup_x, $popup_y );
  
  # Grab the focus and the pointer.
  Gtk2 -> grab_add($popup);
  $popup -> grab_focus();

  Gtk2::Gdk -> pointer_grab($popup -> window(),
                            1,
                            [qw(button-press-mask
                                button-release-mask
                                pointer-motion-mask)],
                            undef,
                            undef,
                            0);

  return;
}

sub get_time_string {
  my $cell = shift;
  return $cell->get ('time');
}

sub calc_size {
  my ($cell, $layout) = @_;
  my ($width, $height) = $layout -> get_pixel_size();

  return (0,
          0,
          $width + x_padding * 2 + arrow_width,
          $height + y_padding * 2);
}

sub GET_SIZE {
  my ($cell, $widget, $cell_area) = @_;

  my $layout = $cell -> get_layout($widget);
  $layout -> set_text($cell -> get_time_string());

  return $cell -> calc_size($layout);
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
  $layout -> set_text($cell -> get_time_string());

  my ($x_offset, $y_offset, $width, $height) = $cell -> calc_size($layout);

  $widget -> get_style -> paint_layout($window,
                                       $state,
                                       1,
                                       $cell_area,
                                       $widget,
                                       "cellrenderertext",
                                       $cell_area -> x() + $x_offset + x_padding,
                                       $cell_area -> y() + $y_offset + y_padding,
                                       $layout);

  $widget -> get_style -> paint_arrow ($window,
                                       $widget->state,
                                       'none',
                                       $cell_area,
                                       $cell -> { _arrow },
                                       "",
                                       "down",
                                       1,
                                       $cell_area -> x + $cell_area -> width - arrow_width,
                                       $cell_area -> y + $cell_area -> height - arrow_height - 2,
                                       arrow_width - 3,
                                       arrow_height);
}

1;

#######################################################################################


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
                      sql          => {
                                           select        => "FirstName, LastName, GroupNo, Active",
                                           from          => "BirdsOfAFeather",
                                           order_by      => "LastName"
                                      },
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

=over 4

Object constructor. Expects a hash of key / value pairs. Bare minimum are:
  
  dbh             - a DBI database handle
  sql             - a hash describing the SQL to execute ( see below )

Other keys accepted are:
  
  primary_key     - the primary key of the table you are querying
  multi_selcet    - a boolean to turn on the TreeView's 'multiple' selection mode
  fields          - an array of hashes to describe the fields ( columns ) in the TreeView ( see below )
  read_only       - a boolean to lock datasheet to read-only ( record status indicator will also disappear )
  on_apply        - a reference to some code to run when a recordset is applied ( see below )
  dump_on_error   - a boolean to turn on dumping of SQL string to the STDOUT on a DBI error
  
The SQL object contains the following keys:

  select          - the select clause
  from            - the from clause
  where           - the where clause ( may contain values or placeholders )
  bind_values     - an array of values to bind to placeholders

Note that each clause has it's directive ( ie 'select', 'from', where', 'order by' *ommitted* )

Each item in the 'fields' key is a hash, with the following possible keys:
  
  name            - the name to display in the column's heading
  x_percent       - a percentage of the available width to use for this column
  x_absolute      - an absolute value to use for the width of this column
  renderer        - string name of renderer - possible values are currently:
                    - text           - default if no renderer defined
                    - number         - invokes a customer CellRendererSpin button ( disabled and reverts to text )
                    - combo          - static combo box with a pre-defined list of options
                    - dynamic_combo  - combo box that depends on values in the current row
                    - toggle         - good for boolean values
                    - date           - good for dates - MUST be in YYYY-MM-DD format ( ie most databases should be OK )
                    - hidden         - use this for hidden columns
  model           - a TreeModel to use with a combo renderer
  model_setup     - object describing the setup of a dynamic_combo ( see below )
  validation      - a sub to run after data entry and before the value is accepted to validate data

As of version 0.8, the database schema is queried and a suitable renderer is automatically selected
if one is not specified. You will of course still have to set up combos yourself.

As of version 2.0, the primary key is automatically selected for you if you use MySQL. Note, however,
that this will only work if the FROM clause contains a single table. If you have a multi-table query,
you must specify the primary_key, otherwise the last primary_key encountered will use. I recommend
against using multi-table queries anyway.

In the case of a 'number' renderer, the following keys are also used:

  min             - the minimum value of the spinbutton
  max             - the maximum value of the spinbutton
  digits          - the number of decimal places in the spinbutton
  step            - the value that the spinbutton's buttons spin the value by :)

Note that as my MOFO::CellRendererSpinButton package is broken ( doesn't accept changes to value ),
any fields with a number renderer will currently default back to a text renderer. I will re-enable
the number renderer as soon as I figure out what the problem is. In the meantime, you can always write
a small function that checks for numeric input and refer to it in your field's 'validation' key.

For dynamic_combo renderers, the 'model_setup' object should take the following form:

{

  id              => "ID"
  display         => "Description",
  from            => "SomeTable",
  criteria        => [
                        {
                             field          => "first_where_clause_field",
                             column_name    => "column_name_of_first_value_to_use"
                        },
                        {
                             field          => "second_where_clause_field",
                             column_name    => "column_name_of_second_value_to_use"
                        }
                     ],
  group_by        => "group by ID, Description",
  order_by        => "order by some_field_to_order_by"

}

Briefly ...

The 'id' key defines the primary key in the table you are querying. This is the value that will be
stored in the dynamic_combo column.

The 'display' key defines the text value that will be *displayed* in the the dynamic_combo column,
and also in the list of combo options.

The 'table' key is the source table to query.

The 'criteria' key is an array of hashes for you to define criteria. Inside each hash, you have:

  - 'field' key, which is the field in the table you are querying ( ie it will go into the where clause )
  - 'column_name' key, which is the *SQL* column name to use as limiting value in the where clause

The 'group_by' key is a 'group by' clause. You *shouldn't* need one, but I've added support anyway...

The 'order_by' key is an 'order by' clause

=back

=head2 query ( [ where_object ], [ dont_apply ] )

=over 4

Requeries the DB server. If there are any outstanding changes that haven't been applied to the database,
a dialog will be presented to the user asking if they want to apply updates before requerying.

If a where object is passed, it will replace the existing one.
If dont_apply is set, *no* dialog will appear if there are outstanding changes to the data.

The where_object is a hash:

   {
         where         => a where clause - can include placeholders
         bind_values   => an array of values to bind to placeholders ( optional )
   }

The query method doubles as an 'undo' method if you set the dont_apply flag, eg:

$datasheet->query ( undef, TRUE );

This will requery and reset all the status indicators. See also undo method, below

=back

=head2 undo

=over 4

Basically a convenience function that calls $self->query( undef, TRUE ) ... see above.
I've come to realise that having an undo method makes understanding your code a lot easier later.

=back

=head2 apply

=over 4

Applies all changes ( inserts, deletes, alterations ) in the datasheet to the database.
As changes are applied, the record status indicator will be changed back to the original 'synchronised' icon.

If any errors are encountered, a dialog will be presented with details of the error, and the apply method
will return FALSE without continuing through the records. The user will be able to tell where the apply failed
by looking at the record status indicators ( and considering the error message they were presented ).

=back

=head2 insert ( [ @columns_and_values ] )

=over 4

Inserts a new row in the *model*. The record status indicator will display an 'insert' icon until the record
is applied to the database ( apply method ).

You can optionally set default values by passing them as an array of column numbers and values, eg:
   $datasheet->insert(
                       2   => "Default value for column 2",
                       5   => "Another default - for column 5"
                     );

Note that you can use the column_from_name method for fetching column numbers from field names ( see below ).

As of version 0.8, default values from the database schema are automatically inserted into all columns that
aren't explicitely set as above.

=back

=head2 delete

=over 4

Marks all selected records for deletion, and sets the record status indicator to a 'delete' icon.
The records will remain in the database until the apply method is called.

=back

=head2 column_from_name ( $sql_fieldname )

=over 4

Returns a field's column number in the model. Note that you *must* use the SQL fieldname,
and not the column heading's name in the treeview.

=back

=head2 column_value ( $sql_fieldname )

=over 4

Returns the value of the requested column in the currently selected row.
If multi_select is on and more than 1 row is selected, only the 1st value is returned.
You *must* use the SQL fieldname, and not the column heading's name in the treeview.

=back

=head2 replace_combo_model ( $column_no, $new_model )

=over 4

Replaces the model for a combo renderer with a new one.
You should only use this to replace models for a normal 'combo' renderer.
An example of when you'd want to do this is if the options in your combo depend on a value
on your *main* form ( ie not in the datasheet ), and that value changes.
If you instead want to base your list of options on a value *inside* the datasheet, use
the 'dynamic_combo' renderer instead ( and don't use replace_combo_model on it ).

=back

=head1 USER-DEFINED CALL-BACKS

=head2 on_apply

=over 4

You can specify some code to run *after* changes to a recordset is applied ( see new() method ).
It will be called for *every* record that has been changed. The user-defined code will be
passed a reference to a hash:

 {
    status          => a string, with possible values: 'inserted', 'changed', or 'deleted'
    primary_key     => the primary key of the record in question
 }

=back

=head1 GENERAL RANTING

=head2 Automatic Column Widths

=over 4

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

=back

=head2 Use of Database Schema

=over 4

Version 0.8 introduces querying the database schema to inspect column attributes. This considerably streamlines
the process of setting up the datasheet and inserting records.

If you don't define a renderer, an appropriate one is selected for you based on the field type.
The only renderers you should now have to explicitely define
are 'hidden', 'combo', and 'dynamic_combo'  - the latter 2 you will obviously still have to set up by providing
a model.

When inserting a new record, default values from the database field definitions are also used ( unless you
specify another value via the insert() method ).

=back

=head2 CellRendererCombo

=over 4

If you have Gtk-2.6 or greater, you can use the new CellRendererCombo. Set the renderer to 'combo' and attach
your model to the field definition. You currently *must* have a model with ( numeric ) ID / String pairs, which is the
usual for database applications, so you shouldn't have any problems. See the example application for ... an example.

=back

=head1 AUTHORS

Daniel Kasak - dan@entropy.homelinux.org

=head1 CREDITS

Muppet

 - tirelessly offered help and suggestions in response to my endless list of questions

Torsten Schoenfeld

 - wrote custom CellRendererDate ( from the Gtk2-Perl examples )
 - wrote custom CellRendererText ( with improved focus policy ) in Odot which I used here

Gtk2-Perl Authors

 - obviously without them, I wouldn't have gotten very far ...

Gtk2-Perl list

 - yet more help, suggestions, and general words of encouragement

=head1 BUGS

I think you must be mistaken

=head1 ISSUES

That's right. These are 'issues', not 'bugs' :)

=head2 Accepting Changes to Cells

=over 4

=head3 Custom CellRendererText

There is currently an issue with the custom CellRendererText that causes changes to be *dropped*
if you don't exit the cell in the right way. The 'right' way includes hitting ENTER, or clicking with
the mouse outside the cell, but *INSIDE* the current datasheet. The 'wrong' way includes going from
typing in the cell to immediately clicking something *OUTSIDE* the datasheet. The cell will *not* register
a change in this case. The moral of the story is to hit the ENTER key to accept changes before continuing.

=back

=head3 CellRendererCombo

=over 4

The CellRendererCombo widget has a problem almost identical to the above issue with the custom CellRendererText.
I recommend either hitting the ENTER key or clicking outside the combo but inside the treeview to make
sure changes are registered. I've submitted a bug report at http://bugzilla.gnome.org/show_bug.cgi?id=317387 as
this issue is with a stock gtk feature.

=back

=head1 Other cool things you should know about:

This module is part of an umbrella project, 'Axis Not Evil', which aims to make
Rapid Application Development of database apps using open-source tools a reality.
The project includes:

  Gtk2::Ex::DBI                 - forms
  Gtk2::Ex::Datasheet::DBI      - datasheets
  PDF::ReportWriter             - reports

All the above modules are available via cpan, or for more information, screenshots, etc, see:
http://entropy.homelinux.org/axis_not_evil

=head1 Crank ON!

=cut