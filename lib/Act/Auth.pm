package Act::Auth;

use strict;
use Apache::AuthCookie;
use Apache::Constants qw(OK DONE);
use Digest::MD5 ();

use Act::Config;
use Act::Template::HTML;

use base qw(Apache::AuthCookie);

use constant LOGIN_PAGE => 'login';  # needs corresponding action in Act::Dispatcher

sub access_handler ($$)
{
    my ($self, $r) = @_;

    # disable authentication unless required
    # (Apache doesn't let us do it the other way around)
    if ($Request{private}) {
        # set correct login script url
        $r->dir_config(ActLoginScript => 
                  $Request{conference}
                ? join('/', undef, $Request{conference}, LOGIN_PAGE)
                : join('/', undef, LOGIN_PAGE));

        # don't recognize_user
        $r->set_handlers(PerlFixupHandler  => [\&OK]);
    }
    else {
        $r->set_handlers(PerlAuthenHandler => [\&OK]);
    }
    return OK;
}
sub authen_cred ($$\@)
{
    my ($self, $r, $login, $sent_pw) = @_;

    # error message prefix
    my $prefix = join ' ', map { "[$_]" } $r->connection->remote_ip, $login, $sent_pw;

    # remove leading and trailing spaces
    for ($login, $sent_pw) {
        s/^\s*//;
        s/\s*$//;
    }

    # login and password must be provided
    $login   or do { $r->log_error("$prefix No login name"); return undef; };
    $sent_pw or do { $r->log_error("$prefix No password");   return undef; };

    # search for this user in our database
    my $sth = $Request{dbh}->prepare_cached('SELECT * FROM users WHERE login=?');
    $sth->execute($login);
    my $user = $sth->fetchrow_hashref()
        or do { $r->log_error("$prefix Unknown user"); return undef; };

    # compare les mots de passe
    $sent_pw eq $user->{passwd}
        or do { $r->log_error("$prefix Bad password"); return undef; };

    # user is authenticated - create a session id
    my $digest = Digest::MD5->new;
    $digest->add(rand(9999), time(), $$);
    my $sid = $digest->b64digest();
    $sid =~ s/\W/-/g;

    # store the session in the users table
    $sth = $Request{dbh}->prepare_cached('UPDATE users SET session_id=? WHERE login=?');
    $sth->execute($sid, $login);
    $Request{dbh}->commit;

    # save this user for the content handler
    $Request{user} = $user;
    _update_language();

    return $sid;
}

sub login_form_handler
{
    my $r = $Request{r};

    # HTTP header
    $r->content_type('text/html; charset=iso-8859-1');
    $r->no_cache(1);
    $r->send_http_header();

    # process the login form template
    my $template = Act::Template::HTML->new();
    $template->variables(
        url => $r->prev && $r->prev->uri ? $r->prev->uri : '/',
    );
    $template->process('login.html');
    return DONE;
}

sub authen_ses_key ($$$)
{
    my ($self, $r, $sid) = @_;

    # search for this user in our database
    my $sth = $Request{dbh}->prepare_cached('SELECT * FROM users WHERE session_id=?');
    $sth->execute($sid);
    my $user = $sth->fetchrow_hashref;
    $sth->finish;

    # unknown session id
    return () unless $user;

    # save this user for the content handler
    $Request{user} = $user;
    _update_language();

    return ($user->{login});
}

sub _update_language
{
    unless (defined $Request{user}{language}
         && $Request{language} eq $Request{user}{language})
    {
        my $sth = $Request{dbh}->prepare_cached('UPDATE users SET language=? WHERE login=?');
        $sth->execute($Request{language}, $Request{user}{login});
        $Request{dbh}->commit;
        $Request{user}{language} = $Request{language};
    }
}

1;
__END__
