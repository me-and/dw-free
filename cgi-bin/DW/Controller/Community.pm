#!/usr/bin/perl
#
# Authors:
#      Afuna <coder.dw@afunamatata.com>
#
# Copyright (c) 2013 by Dreamwidth Studios, LLC.
#
# This program is free software; you may redistribute it and/or modify it under
# the same terms as Perl itself. For a copy of the license, please reference
# 'perldoc perlartistic' or 'perldoc perlgpl'.


package DW::Controller::Community;

use strict;
use DW::Controller;
use DW::Routing;
use DW::Template;
use DW::FormErrors;

use POSIX;
use DW::Entry::Moderated;

=head1 NAME

DW::Controller::Community - Community management pages

=cut

DW::Routing->register_string( "/communities/index", \&index_handler, app => 1 );
DW::Routing->register_string( "/communities/list", \&list_handler, app => 1 );
DW::Routing->register_string( "/communities/new", \&new_handler, app => 1 );

DW::Routing->register_regex( '^/communities/([^/]+)/members/edit$', \&members_handler, app => 1 );
DW::Routing->register_string( "/communities/members/purge", \&purge_handler, app => 1, methods => { POST => 1 } );

DW::Routing->register_regex( '^/communities/([^/]+)/queue/entries$', \&entry_queue_handler, app => 1 );
DW::Routing->register_regex( '^/communities/([^/]+)/queue/entries/([0-9]+)$', \&entry_queue_edit_handler, app => 1 );

DW::Routing->register_regex( '^/communities/([^/]+)/queue/members$', \&members_queue_handler, app => 1 );

# redirects
DW::Routing->register_redirect( "/community/index", "/communities/index" );
DW::Routing->register_redirect( "/community/manage", "/communities/list" );
DW::Routing->register_redirect( "/community/create", "/communities/new" );

DW::Routing->register_redirect( "/community/members", "/communities/members/edit", keep_args => [ "authas" ] );
DW::Routing->register_string( "/communities/members/edit", \&members_redirect_handler, app => 1 );
DW::Routing->register_redirect( "/community/moderate", "/communities/queue/entries", keep_args => [ "authas" ] );
DW::Routing->register_string( "/communities/queue/entries", \&entry_queue_redirect_handler, app => 1 );
DW::Routing->register_redirect( "/community/pending", "/communities/queue/members", keep_args => [ "authas" ] );
DW::Routing->register_string( "/communities/queue/members", \&member_queue_redirect_handler, app => 1 );

sub _redirect_authas {
    my $redirect_path = $_[0];

    my $r = DW::Request->get;
    my $get = $r->get_args;

    my $authas = LJ::eurl( $get->{authas});
    if ( $authas ) {
        return $r->redirect( "$LJ::SITEROOT/communities/$authas/$redirect_path" );
    } else {
        return $r->redirect( "$LJ::SITEROOT/communities/list" );
    }
}

sub members_redirect_handler      { return _redirect_authas( "members/edit" ); }
sub entry_queue_redirect_handler  { return _redirect_authas( "queue/entries" ); }
sub member_queue_redirect_handler { return _redirect_authas( "queue/members" ); }


sub index_handler {
    my ( $ok, $rv ) = controller( anonymous => 1 );
    return $rv unless $ok;

    my $vars = {
        remote => $rv->{remote},
        remote_admins_communities => @{LJ::load_rel_target( $rv->{remote}, 'A' ) || []} ? 1 : 0,
        community_manage_links => LJ::Hooks::run_hook( 'community_manage_links' ) || "",

        # implemented as a hook because most/all the links are to
        # dreamwidth.org-specific FAQs. see cgi-bin/DW/Hooks/Community.pm
        # in dw-nonfree as an example to create your own.
        faq_links => LJ::Hooks::run_hook( 'community_faqs' ) || "",

        # hook is to list dw-community-promo;
        # define your own in a hook if you have a similar community or want to
        # add other links to the list.
        community_search_links => LJ::Hooks::run_hook( 'community_search_links' ) || "",

        recently_active_comms => DW::Widget::RecentlyActiveComms->render,
        newly_created_comms => DW::Widget::NewlyCreatedComms->render,
        official_comms => LJ::Hooks::run_hook( 'official_comms' ) || "",
    };

    return DW::Template->render_template( 'communities/index.tt', $vars );
}

sub list_handler {
    my ( $ok, $rv ) = controller();
    return $rv unless $ok;

    my $remote = $rv->{remote};

    my @comms_managed = $remote->communities_managed_list;
    my @comms_moderated = $remote->communities_moderated_list;

    # 'foo' => {
    #   user      => 'foo'
    #   ljuser    => '<.... user=foo>'
    #   title     => 'Community for Foo Enthusiasts',
    #   mod_queue_count         => 123,
    #   pending_members_count   => 456,
    # }
    my %communities;

    foreach my $cu ( @comms_managed, @comms_moderated ) {
        $communities{$cu->user} = {
            user     => $cu->user,
            ljuser   => $cu->ljuser_display,
            title    => $cu->name_raw,
            moderation_queue_url => $cu->moderation_queue_url,
            member_queue_url     => $cu->member_queue_url,
        };
    }

    foreach my $cu ( @comms_managed ) {
        my $comm_representation = $communities{$cu->user};
        $comm_representation->{admin} = 1;

        my $pending_members = $cu->is_moderated_membership
                                ? $cu->get_pending_members_count
                                : 0;
        $comm_representation->{pending_members_count} = $pending_members;
    }

    foreach my $cu ( @comms_moderated ) {
        my $comm_representation = $communities{$cu->user};
        $comm_representation->{moderator} = 1;

        # we don't rely on $cu->has_moderated_posting
        # because we may still have posts in the queue
        # e.g., after a switch from moderated posting to non-moderated posting
        my $mod_queue = $cu->get_mod_queue_count;
        my $should_show_queue = $cu->has_moderated_posting || $mod_queue;
        $comm_representation->{show_mod_queue_count} = $should_show_queue;
        $comm_representation->{mod_queue_count} = $cu->get_mod_queue_count
            if $should_show_queue;
    }

    my @sorted_communities = sort { $a cmp $b }
                keys %communities;
    my $vars = {
        community_list => [ @communities{@sorted_communities} ],
    };

    return DW::Template->render_template( 'communities/list.tt', $vars );
}

sub new_handler {
    my ( $ok, $rv ) = controller( form_auth => 1 );
    return $rv unless $ok;

    my $remote = $rv->{remote};
    my $r = $rv->{r};
    my $post;
    my $get;

    return error_ml( 'bml.badinput.body' ) unless LJ::text_in( $post );
    return error_ml( '/communities/new.tt.error.notactive' ) unless $remote->is_visible;
    return error_ml( '/communities/new.tt.error.notconfirmed', {
            confirm_url => "$LJ::SITEROOT/register",
        }) unless $remote->is_validated;

    my %default_options = (
        membership  => 'open',
        postlevel   => 'members',
        moderated   => '0',
        nonmember_posting   => '0',
        age_restriction     => 'none'
    );

    my $errors = DW::FormErrors->new;
    if ( $r->did_post ) {
        $post = $r->post_args;

        # checks that the POSTed option is valid
        # if not, force it to the default option
        my $validate = sub {
            my ( $key, $regex ) = @_;

            $post->set( $key, $default_options{$key} )
                unless $post->{$key} =~ $regex;
        };

        $validate->( "membership",          qr/^(?:open|moderated|closed)$/ );
        $validate->( "postlevel",           qr/^(?:members|select)$/ );
        $validate->( "nonmember_posting",   qr/^[01]$/ );
        $validate->( "moderated",           qr/^[01]$/ );
        $validate->( "age_restriction",     qr/^(?:none|concepts|explicit)$/ );


        my $new_user = LJ::canonical_username( $post->{user} );
        my $title = $post->{title} || $new_user;

        if ( LJ::sysban_check( 'email', $remote->email_raw ) ) {
            LJ::Sysban::block( 0, "Create user blocked based on email",
                        { new_user => $new_user, email => $remote->email_raw, name => $new_user } );
            return $r->HTTP_SERVICE_UNAVAILABLE;
        }

        if ( ! $post->{user} ) {
            $errors->add( "user", ".error.user.mustenter" );
        } elsif( ! $new_user ) {
            $errors->add( "user", "error.usernameinvalid" );
        } elsif ( length $new_user > 25 ) {
            $errors->add( "user", "error.usernamelong" );
        }

        # disallow creating communities matched against the deny list
        $errors->add( "user", ".error.user.reserved" )
            if LJ::User->is_protected_username( $new_user );

        # now try to actually create the community
        my $second_submit;
        my $cu = LJ::load_user( $new_user );

        if ( $cu && $cu->is_expunged ) {
            $errors->add( "user", "widget.createaccount.error.username.purged",
                                        { aopts => "href='$LJ::SITEROOT/rename/'" } );
        } elsif ( $cu ) {
            # community was created in the last 10 minutes?
            my $recent_create = ( $cu->timecreate > (time() - (10*60)) ) ? 1 : 0;
            $second_submit = ( $cu->is_community && $recent_create
                                && $remote->can_manage_other( $cu ) ) ? 1 : 0;
            $errors->add( "user", ".error.user.inuse" ) unless $second_submit;
        }

        unless ( $errors->exist ) {
            # rate limit
            return error_ml( "/communities/new.tt.error.ratelimited" )
                unless $remote->rate_log( 'commcreate', 1 );

            $cu = LJ::User->create_community (
                    user        => $new_user,
                    status      => $remote->email_status,
                    name        => $title,
                    email       => $remote->email_raw,
                    membership  => $post->{membership},
                    postlevel   => $post->{postlevel},
                    moderated   => $post->{moderated},
                    nonmember_posting       => $post->{nonmember_posting},
                    journal_adult_settings  => $post->{age_restriction},
                ) unless $second_submit;

            return DW::Template->render_template( 'communities/new-success.tt', {
                community => {
                    ljuser  => $cu->ljuser_display,
                    user    => $cu->user,
                }
            }) if $cu;
        }
    } else {
        $get = $r->get_args;
    }

    my $vars = {
        age_restriction_enabled => LJ::is_enabled( 'adult_content' ),

        errors => $errors,
    };

    $vars->{formdata} = $post || {
                                user => $get->{user},
                                title => $get->{title},

                                # initial radio button selection
                                %default_options
                            };

    return DW::Template->render_template( 'communities/new.tt', $vars );
}

# return the appropriate slice from the full array for this page
# ideally we'd do this when fetching from the DB
sub _items_for_this_page {
    my ( $page, $page_size, @items ) = @_;
    my $first = ( $page - 1 ) * $page_size;

    my $num_items = scalar @items;
    my $last = $page * $page_size;
    $last = $num_items if $last > $num_items;
    $last = $last - 1;

    return @items[$first...$last];
}

sub members_handler {
    my ( $opts, $cuser ) = @_;

    my ( $ok, $rv ) = controller( form_auth => 1 );
    return $rv unless $ok;

    my $r = $rv->{r};
    my $remote = $rv->{remote};

    my $get = $r->get_args;

    # now get lists of: members, admins, able to post, moderators
    my %roletype_to_readable = (
                    A => 'admin',
                    P => 'poster',
                    E => 'member',
                    M => 'moderator',
                    N => 'unmoderated'
                    );
    my %readable_to_roletype = reverse %roletype_to_readable;
    my @roles = keys %readable_to_roletype;

    my $cu = LJ::load_user( $cuser );
    return error_ml( "/communities/members/edit.tt.error.nocomm" ) unless $cu;

    return error_ml( "/communities/members/edit.tt.error.notcomm", {
                        user => $cu->ljuser_display,
                    } ) unless $cu->is_comm;

    return error_ml( "/communities/members/edit.tt.error.noaccess", {
                        comm => $cu->ljuser_display,
                    } ) unless $remote->can_manage_other( $cu );

    # handle post
    my @messages;
    my @roles_changed;
    my $errors = DW::FormErrors->new;
    if ( $r->did_post ) {
        my $post = $r->post_args;

        my %was;
        my %current;
        foreach my $role ( @roles ) {
            # quick lookup for checkboxes that were checked on page load (old values{})
            foreach my $uid ( $post->get_all( $role . "_old" ) ) {
                $was{$uid}->{$role} = 1;
            }

            # and same for current values
            foreach my $uid ( $post->get_all( $role ) ) {
                $current{$uid}->{$role} = 1;
            }
        }

        # preload the users we're dealing with
        # assumes that every user has at least one checked checkbox...
        # but that seems to be a fair assumption
        my @preload_userids = grep { $_ } map { $_ + 0 } keys %was;
        my %us = %{ LJ::load_userids( @preload_userids ) };

        # now compare userids in %current to %was
        # to determine which to add and which to delete
        my ( %add, %delete );                           # role -> userid mapping
        my ( %add_user_to_role, %delete_user_to_role ); # userid -> role mappings

        foreach my $uid ( @preload_userids ) {
            foreach my $role ( @roles ) {
                if ( $current{$uid}->{$role} && ! $was{$uid}->{$role} ) {
                    $add{$role}->{$uid} = 1;
                    $add_user_to_role{$uid}->{$role} = 1;
                } elsif ( $was{$uid}->{$role} && ! $current{$uid}->{$role}) {
                    $delete{$role}->{$uid} = 1;
                    $delete_user_to_role{$uid}->{$role} = 1;
                }
            }
        }

        ########
        ## ADD

        # members are a special-case, because we need to ask permission first
        foreach my $uid ( keys %{$add{member} || {}} ) {
            my $add_u = $us{$uid};
            next unless $add_u;

            if ( $remote->equals( $add_u ) ) {
                    # you're allowed to add yourself as member
                    $remote->join_community( $cu );
                } else {
                    if ( $add_u && $add_u->send_comm_invite( $cu, $remote, [ 'member' ] ) ) {
                       push @messages,  [ ".msg.invite",
                                           { user => $add_u->ljuser_display, invite_url => "$LJ::SITEROOT/manage/invites" } ];
                    }
                }
        }

        # admins also need special handling: they should be notified that they've been added
        foreach my $uid ( keys %{$add{admin} || {}} ) {
            my $add_u = $us{$uid};
            next unless $add_u;

            $cu->notify_administrator_add( $add_u, $remote );
        }

        # go ahead and add poster (P), unmoderated (N), moderator (M), admin (A) edges unconditionally
        my $cid = $cu->userid;
        LJ::set_rel_multi( (map { [$cid, $_, 'A'] } keys %{$add{admin}       || {}}),
                           (map { [$cid, $_, 'P'] } keys %{$add{poster}      || {}}),
                           (map { [$cid, $_, 'M'] } keys %{$add{moderator}   || {}}),
                           (map { [$cid, $_, 'N'] } keys %{$add{unmoderated} || {}}),
                           );


        ##########
        ## DELETE

        # delete members
        foreach my $uid ( keys %{$delete{member} || {}} ) {
            my $del_u = $us{$uid};
            next unless $del_u;

            $del_u->remove_edge( $cid, member => {} );
        }

        # admins are a special case: we need to make sure we don't remove all admins from the community

        # we load the admin_users in bulk separately, because this list might include admins that weren't available on this page
        # (but we still want to be able to load them up to check their visibility status)
        my %admin_users = %{ LJ::load_userids( $cu->maintainer_userids ) };

        my %admins_to_delete = %{$delete{admin} || {}};
        my @remaining_admins = grep { ! $admins_to_delete{ $_ }             # admins we want to delete on this page load
                                        && $admin_users{$_}                 # is an existing user
                                        && ! $admin_users{$_}->is_expunged  # that is not expunged
                                    } $cu->maintainer_userids;

        unless ( @remaining_admins ) {
            $errors->add( "admin", ".error.no_admin", { comm => $cu->ljuser_display } );

            # refuse to delete any admins
            $delete{admin} = {};
        }

        # now notify admins that we're deleting
        foreach my $uid ( keys %{$delete{admin} || {}} ) {
            my $del_u = $us{$uid};
            next if ! $del_u || $del_u->is_expunged;

            $cu->notify_administrator_remove( $del_u, $remote );
        }

        # go ahead and delete poster (P), unmoderated (N), moderator (M), admin (A) edges unconditionally
        LJ::clear_rel_multi(
                            (map { [$cid, $_, 'A'] } keys %{$delete{admin}       || {}}),
                            (map { [$cid, $_, 'P'] } keys %{$delete{poster}      || {}}),
                            (map { [$cid, $_, 'M'] } keys %{$delete{moderator}   || {}}),
                            (map { [$cid, $_, 'N'] } keys %{$delete{unmoderated} || {}}),
                            );


        ###############
        ## CLEAR CACHE

        # delete reluser memcache key
        LJ::MemCache::delete([ $cid, "reluser:$cid:A" ]);
        LJ::MemCache::delete([ $cid, "reluser:$cid:P" ]);
        LJ::MemCache::delete([ $cid, "reluser:$cid:M" ]);
        LJ::MemCache::delete([ $cid, "reluser:$cid:N" ]);


        ####################
        ## SUCCESS MESSAGES

        # now show messages for each succesful change we did
        my %done;
        my %role_strings = map { $_ => LJ::Lang::ml( "/communities/members/edit.tt.role.$_" ) } %readable_to_roletype;
        my $remote_uid = $remote->userid;
        foreach my $uid ( keys %add_user_to_role, keys %delete_user_to_role ) {
            next if $done{$uid}++;

            my $u = $us{$uid};
            next unless $u;

            my ( $changed_roles_msg, @added_roles, @removed_roles );
            push @added_roles, $role_strings{$_}
                foreach grep { $_ ne "member"           # reinvited members need to confirm, so we don't want a success message
                                || $uid == $remote_uid  # but if you're adding yourself as a member, that's fine
                            } keys %{$add_user_to_role{$uid} || {}};
            push @removed_roles , $role_strings{$_}
                foreach keys %{$delete_user_to_role{$uid} || {}};
            push @roles_changed, { user => $u->ljuser_display, added => \@added_roles, removed => \@removed_roles } if @added_roles || @removed_roles;
        }

    }

    my @role_filters = split ",", $get->{role} || "";
    @role_filters = grep { $_ } # make sure it's a valid role
                map { $readable_to_roletype{$_} } @role_filters;
    my %active_role_filters = map { $roletype_to_readable{$_} => 1 } @role_filters;

    my ( $users, $role_count );
    if ( $get->{q} ) {
        # we return results for just this user

        my $query_u = LJ::load_user( $get->{q} );
        ( $users, $role_count ) = $cu->get_member( $query_u );
    } else {
        # grab the list of users (optionally by role)

        ( $users, $role_count ) = $cu->get_members_by_role( \@role_filters );
    }

    my $page = int( $get->{page} || 0 ) || 1;
    my $page_size = 100;

    my @users = sort { $a->{name} cmp $b->{name} } values %$users;

    # pagination:
    #   calculate the number of pages
    #   take the results and choose only a slice for display
    my $total_pages = ceil( scalar @users / $page_size );
    @users = _items_for_this_page( $page, $page_size, @users );

    # populate with the ljuser tag for display
    $_->{ljuser} = LJ::ljuser( $_->{name} ) foreach @users;

    # figure out what member roles are relevant
    my @available_roles = ( 'member', 'poster' );
    my $has_moderated_posting = $cu->has_moderated_posting;
    push @available_roles, 'unmoderated'
        if $has_moderated_posting || $role_count->{N};
    push @available_roles, 'moderator'
        if $has_moderated_posting || $role_count->{M};
    push @available_roles, 'admin';

    # create a data structure for the links to filter members
    my $filter_link = sub {
        my $filter = $_[0];
        return
        {   text    => ".role.$filter",
            url     => LJ::create_url( undef, args => { role => "$filter" } ),
            active  => $active_role_filters{$filter} ? 1 : 0,
        },
    };

    my @filter_links = (
        {   text    => ".role.all",
            url     => LJ::create_url( undef ),
            active  => ( scalar keys %active_role_filters ) || $get->{q} ? 0 : 1,
        }
     );

    push @filter_links, $filter_link->( $_ ) foreach @available_roles;

    # data for the checkboxes in the form of:
    #   {
    #       role => [ userids ], ...
    #  }
    my $membership_statuses = Hash::MultiValue->new;
    my @roletype_keys = keys %roletype_to_readable;

    foreach my $user ( values %$users ) {
        foreach my $roletype ( @roletype_keys ) {
            $membership_statuses->add( $roletype_to_readable{$roletype}, $user->{userid} )
                if $user->{$roletype};
        }
    }

    my $vars = {
        community => $cu,
        user_list => \@users,

        roles        => \@available_roles,
        filter_links => \@filter_links,
        pages        => { current => $page, total_pages => $total_pages },
        has_active_filter => keys %active_role_filters ? 1 : 0,

        formdata      => $membership_statuses,
        messages      => \@messages,
        roles_changed => \@roles_changed,
        errors        => $errors,

        form_edit_action_url => LJ::create_url( undef, keep_args => [qw( role page )] ),
        form_search_action_url => LJ::create_url( undef ),
        form_purge_action_url => LJ::create_url( "/communities/members/purge" ),
    };

    return DW::Template->render_template( 'communities/members/edit.tt', $vars );
}

sub purge_handler {
    my ( $opts ) = @_;

    my ( $ok, $rv ) = controller( form_auth => 0 );
    return $rv unless $ok;

    my $r = $rv->{r};
    my $post = $r->post_args;
    my $remote = $rv->{remote};

    my $cu = LJ::load_user( $post->{authas} );
    return error_ml( "/communities/members/edit.tt.error.nocomm" ) unless $cu;

    return error_ml( "/communities/members/edit.tt.error.notcomm", {
                        user => $cu->ljuser_display,
                    } ) unless $cu->is_comm;

    return error_ml( "/communities/members/edit.tt.error.noaccess", {
                        comm => $cu->ljuser_display,
                    } ) unless $remote->can_manage_other( $cu );


    my $members = LJ::load_userids( $cu->member_userids );
    my @purged = map { name => $_->ljuser_display, id => $_->userid },
                 sort { $a->user cmp $b->user }
                 grep { $_ && $_->is_expunged } values %$members;

    my $members_url = LJ::create_url( "/communities/" . $cu->user . "/members/edit" );
    my $vars = {
        user_list => \@purged,
        community => $cu,

        roles => [ qw( admin poster member moderator unmoderated ) ],

        form_action => $members_url,
        members_url => $members_url,
    };

    return DW::Template->render_template( 'communities/members/purge.tt', $vars );
}

# returns ( $can_moderate, ".error_ml", { error_ml_args => foo } )
sub _check_entry_queue_auth {
    my ( $cu, $remote ) = @_;

    my $ml_scope = "/communities/queue/entries.tt";

    return ( 0, "$ml_scope.error.notfound" ) unless $cu;

    unless ( $remote->can_moderate( $cu ) ) {
        return ( 0, "$ml_scope.error.noaccess", { comm => $cu->ljuser_display } )
            if $cu->has_moderated_posting;

        return ( 0, "$ml_scope.error.notmoderated" );
    }
}

sub entry_queue_handler {
    my ( $opts, $community ) = @_;

    my ( $ok, $rv ) = controller( form_auth => 0 );
    return $rv unless $ok;

    my $cu = LJ::load_user( $community );

    my ( $can_moderate, @error ) = _check_entry_queue_auth( $cu, $rv->{remote} );
    return error_ml( @error ) unless $can_moderate;

    my $r = $rv->{r};
    my @queue = $cu->get_mod_queue;

    my %users;
    LJ::load_userids_multiple([ map { $_->{posterid}, \$users{$_->{posterid}} } @queue ]);

    my @entries = map {
            {
                time    => LJ::diff_ago_text( LJ::mysqldate_to_time( $_->{logtime} ) ),
                poster  => $users{$_->{posterid}}->ljuser_display,
                subject => $_->{subject},
                url     => $cu->moderation_queue_url( $_->{modid} ),
            }
        } @queue;

    my $vars = {
        entries => \@entries,
    };

    return DW::Template->render_template( 'communities/queue/entries.tt', $vars );
}

sub entry_queue_edit_handler {
    my ( $opts, $community, $modid ) = @_;

    $modid = int $modid;

    my ( $ok, $rv ) = controller( form_auth => 1 );
    return $rv unless $ok;

    my $cu = LJ::load_user( $community );

    my ( $can_moderate, @error ) = _check_entry_queue_auth( $cu, $rv->{remote} );
    return error_ml( @error ) unless $can_moderate;

    my $moderated_entry = DW::Entry::Moderated->new( $cu, $modid );
    return error_ml( "/communities/queue/entries/edit.tt.error.no_entry") unless $moderated_entry;

    my $r = $rv->{r};

    my $errors = DW::FormErrors->new;
    if ( $r->did_post ) {
        my $post = $r->post_args;
        my $status_vars = { queue_url => $cu->moderation_queue_url };

        return error_ml( "/communities/queue/entries/edit.tt.error.no_entry" )
            unless $moderated_entry->auth eq $post->{auth};

        if ( $post->{"action:approve"} || $post->{"action:preapprove"} ) {
            my ( $approve_ok, $approve_rv ) = $moderated_entry->approve;
            if ( $approve_ok ) {
                $moderated_entry->notify_poster( "approved",
                                   entry_url => $approve_rv,
                                   message => $post->{message}
                                );

                $status_vars->{status} = "approved";
                $status_vars->{entry_url} = $approve_rv;
            } else {
                $moderated_entry->notify_poster( "error", error => $approve_rv );

                $errors->add( undef, "/communities/queue/entries/edit.tt.error.post", { error => $approve_rv } );
            }

            if ( $post->{"action:preapprove"} ) {
                LJ::set_rel( $moderated_entry->journal, $moderated_entry->poster, 'N' );

                $status_vars->{preapproved} = 1;
                $status_vars->{user} = $moderated_entry->poster->ljuser_display;
                $status_vars->{community} = $moderated_entry->journal->ljuser_display;
            }
        }

        if ( $post->{"action:reject"} || $post->{"action:spam"} ) {
            my $reject_ok = $post->{"action:spam"} ? $moderated_entry->reject_as_spam : $moderated_entry->reject;
            $moderated_entry->notify_poster( "rejected",
                                            message => $post->{message},
                                        ) if $reject_ok;

            $status_vars->{status} = "rejected";

            $errors->add( undef, ".error.cant_spam" ) unless $reject_ok;
        }

        return DW::Template->render_template( 'communities/queue/entries/edit-status.tt', $status_vars )
            unless $errors->exist;
    }

    my $vars = {
        entry   =>  {   icon    => $moderated_entry->icon,
                        poster  => $moderated_entry->poster,
                        journal => $moderated_entry->journal,
                        time    => $moderated_entry->time( linkify => 1 ),

                        subject => $moderated_entry->subject,
                        event   => $moderated_entry->event,
                        age_restriction_reason => $moderated_entry->age_restriction_reason,

                        auth    => $moderated_entry->auth,

                        currents_html => $moderated_entry->currents_html,
                        security_html =>$moderated_entry->security_html,
                        age_restriction_html => $moderated_entry->age_restriction_html,
                    },

        moderate_url => LJ::create_url( undef ),
        can_report_spam => LJ::sysban_check( 'spamreport', $cu->user ) ? 0 : 1,

        errors => $errors,
    };

    return DW::Template->render_template( 'communities/queue/entries/edit.tt', $vars );
}

sub members_queue_handler {
    my ( $opts, $community ) = @_;

    my ( $ok, $rv ) = controller( form_auth => 1 );
    return $rv unless $ok;

    my $r = $rv->{r};
    my $remote = $rv->{remote};
    my $get = $r->get_args;

    my $cu = LJ::load_user( $community );
    return error_ml( "/communities/queue/members.tt.error.notfound" ) unless $cu;
    return error_ml( "/communities/queue/members.tt.error.noaccess", {
            comm => $cu->ljuser_display,
        } ) unless $remote->can_manage_other( $cu );


    # now load all users with a pending membership request
    my $pendids = $cu->get_pending_members || [];
    my $us = LJ::load_userids( @$pendids );

    my @success_msgs;
    if ( $r->did_post ) {
        my $post = $r->post_args;

        my @statuses = qw(  approve reject ban ban_skip
                            previously_handled
                        );
        my %status_count = map { $_ => 0 } @statuses;
        $post->each( sub {
            my ( $key, $action ) = @_;

            my $uid;
            return unless ( $uid ) = $key =~ m/user_(\d+)/;

            my $pending_u = $us->{$uid};

            if ( ! $pending_u ) {
                # POSTed but not in pending users. Looks like it was handled by someone else
                $status_count{previously_handled}++;
            } elsif ( $action eq "approve" ) {
                $cu->approve_pending_member( $pending_u );
                $status_count{approve}++;
            } elsif ( $action eq "reject" ) {
                $cu->reject_pending_member( $pending_u );
                $status_count{reject}++;
            } elsif ( $action eq "ban" ) {
                my $banlist = LJ::load_rel_user( $cu, 'B' ) || [];
                if ( scalar( @$banlist ) >= ( $LJ::MAX_BANS || 5000 ) ) {
                    $status_count{ban_skip}++;
                } else {
                    $cu->ban_user( $pending_u );
                    $status_count{ban}++;

                    # ban is successful, reject member
                    # $cu->reject_pending_member( $pending_u ); # only in case of successful ban
                }
            }
        });

        foreach my $status ( @statuses ) {
            push @success_msgs, { ml => ".success.$status" , num => $status_count{$status} }
                if $status_count{$status};
        }

        # get the list of pending members again; may have changed
        $pendids = $cu->get_pending_members || [];
        $us = LJ::load_userids( @$pendids );
    }

    my $page = int( $get->{page} || 0 ) || 1;
    my $page_size = 100;

    my @users = sort { $a->{user} cmp $b->{user} } values %$us;

    # pagination:
    #   calculate the number of pages
    #   take the results and choose only a slice for display
    my $total_pages = ceil( scalar @users / $page_size );
    @users = _items_for_this_page( $page, $page_size, @users );

    my $vars = {
        user_list   => [ map { {
                            userid => $_->userid,
                            ljuser => $_->ljuser_display,
            }} @users ],
        pages       => { current => $page, total_pages => $total_pages },
        messages    => \@success_msgs,

        form_queue_action_url => LJ::create_url( undef, keep_args => [qw( page )] ),
    };

    return DW::Template->render_template( 'communities/queue/members.tt', $vars );

}

1;