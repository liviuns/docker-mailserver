#!/bin/sh

# Packages
# hadolint ignore=DL3015
echo "deb http://http.debian.net/debian stretch-backports main" | tee -a /etc/apt/sources.list.d/stretch-bp.list &&
  apt-get update -q --fix-missing &&
  apt-get -y install postfix &&
  # TODO installing postfix with --no-install-recommends makes "checking ssl: generated default cert works correctly" fail
  apt-get -y install --no-install-recommends \
    amavisd-new \
    apt-transport-https \
    arj \
    binutils \
    bzip2 \
    ca-certificates \
    cabextract \
    clamav \
    clamav-daemon \
    cpio \
    curl \
    ed \
    fail2ban \
    fetchmail \
    file \
    gamin \
    gzip \
    gnupg \
    iproute2 \
    iptables \
    locales \
    logwatch \
    libdate-manip-perl \
    liblz4-tool \
    libmail-spf-perl \
    libnet-dns-perl \
    libsasl2-modules \
    lrzip \
    lzop \
    netcat-openbsd \
    nomarch \
    opendkim \
    opendkim-tools \
    opendmarc \
    pax \
    pflogsumm \
    p7zip-full \
    postfix-ldap \
    postfix-pcre \
    postfix-policyd-spf-python \
    postsrsd \
    pyzor \
    razor \
    ripole \
    rpm2cpio \
    rsyslog \
    sasl2-bin \
    spamassassin \
    supervisor \
    postgrey \
    unrar-free \
    unzip \
    whois \
    xz-utils \
    zoo &&
  # use Dovecot community repo to react faster on security updates
  curl https://repo.dovecot.org/DOVECOT-REPO-GPG | gpg --import &&
  gpg --export ED409DA1 >/etc/apt/trusted.gpg.d/dovecot.gpg &&
  echo "deb https://repo.dovecot.org/ce-2.3-latest/debian/stretch stretch main" >/etc/apt/sources.list.d/dovecot-community.list &&
  apt-get update -q --fix-missing &&
  apt-get -y install --no-install-recommends \
    dovecot-core \
    dovecot-imapd \
    dovecot-ldap \
    dovecot-lmtpd \
    dovecot-managesieved \
    dovecot-pop3d \
    dovecot-sieve \
    dovecot-solr &&
  apt-get autoclean &&
  rm -rf /var/lib/apt/lists/* &&
  rm -rf /usr/share/locale/* &&
  rm -rf /usr/share/man/* &&
  rm -rf /usr/share/doc/* &&
  touch /var/log/auth.log &&
  update-locale &&
  rm -f /etc/cron.weekly/fstrim &&
  rm -f /etc/postsrsd.secret &&
  rm -f /etc/cron.daily/00logwatch

# install filebeat for logging
curl https://packages.elasticsearch.org/GPG-KEY-elasticsearch | apt-key add - &&
  echo "deb http://packages.elastic.co/beats/apt stable main" | tee -a /etc/apt/sources.list.d/beats.list &&
  apt-get update -q --fix-missing &&
  apt-get -y install --no-install-recommends \
    filebeat &&
  apt-get clean &&
  rm -rf /var/lib/apt/lists/*

cp target/filebeat.yml.tmpl /etc/filebeat/filebeat.yml.tmpl

echo "0 */6 * * * clamav /usr/bin/freshclam --quiet" >/etc/cron.d/clamav-freshclam &&
  chmod 644 /etc/clamav/freshclam.conf &&
  freshclam &&
  sed -i 's/Foreground false/Foreground true/g' /etc/clamav/clamd.conf &&
  sed -i 's/AllowSupplementaryGroups false/AllowSupplementaryGroups true/g' /etc/clamav/clamd.conf &&
  mkdir /var/run/clamav &&
  chown -R clamav:root /var/run/clamav &&
  rm -rf /var/log/clamav/

# Configures Dovecot
cp target/dovecot/auth-passwdfile.inc /etc/dovecot/conf.d/
cp target/dovecot/*.conf /etc/dovecot/conf.d/

cd /usr/share/dovecot
# hadolint ignore=SC2016,SC2086
sed -i -e 's/include_try \/usr\/share\/dovecot\/protocols\.d/include_try \/etc\/dovecot\/protocols\.d/g' /etc/dovecot/dovecot.conf &&
  sed -i -e 's/#mail_plugins = \$mail_plugins/mail_plugins = \$mail_plugins sieve/g' /etc/dovecot/conf.d/15-lda.conf &&
  sed -i -e 's/^.*lda_mailbox_autocreate.*/lda_mailbox_autocreate = yes/g' /etc/dovecot/conf.d/15-lda.conf &&
  sed -i -e 's/^.*lda_mailbox_autosubscribe.*/lda_mailbox_autosubscribe = yes/g' /etc/dovecot/conf.d/15-lda.conf &&
  sed -i -e 's/^.*postmaster_address.*/postmaster_address = '${POSTMASTER_ADDRESS:="postmaster@domain.com"}'/g' /etc/dovecot/conf.d/15-lda.conf &&
  sed -i 's/#imap_idle_notify_interval = 2 mins/imap_idle_notify_interval = 29 mins/' /etc/dovecot/conf.d/20-imap.conf &&
  # Adapt mkcert for Dovecot community repo
  sed -i 's/CERTDIR=.*/CERTDIR=\/etc\/dovecot\/ssl/g' /usr/share/dovecot/mkcert.sh &&
  sed -i 's/KEYDIR=.*/KEYDIR=\/etc\/dovecot\/ssl/g' /usr/share/dovecot/mkcert.sh &&
  sed -i 's/KEYFILE=.*/KEYFILE=\$KEYDIR\/dovecot.key/g' /usr/share/dovecot/mkcert.sh &&
  # create directory for certificates created by mkcert
  mkdir /etc/dovecot/ssl &&
  chmod 755 /etc/dovecot/ssl &&
  ./mkcert.sh &&
  mkdir -p /usr/lib/dovecot/sieve-pipe /usr/lib/dovecot/sieve-filter /usr/lib/dovecot/sieve-global &&
  chmod 755 -R /usr/lib/dovecot/sieve-pipe /usr/lib/dovecot/sieve-filter /usr/lib/dovecot/sieve-global

# Configures LDAP
cp target/dovecot/dovecot-ldap.conf.ext /etc/dovecot
cp target/postfix/ldap-users.cf /etc/postfix/
cp target/postfix/ldap-groups.cf /etc/postfix/
cp target/postfix/ldap-aliases.cf /etc/postfix/
cp target/postfix/ldap-domains.cf /etc/postfix/

# Enables Spamassassin CRON updates and update hook for supervisor
# hadolint ignore=SC2016
sed -i -r 's/^(CRON)=0/\1=1/g' /etc/default/spamassassin &&
  sed -i -r 's/^\$INIT restart/supervisorctl restart amavis/g' /etc/spamassassin/sa-update-hooks.d/amavisd-new

# Enables Postgrey
cp target/postgrey/postgrey /etc/default/postgrey
cp target/postgrey/postgrey.init /etc/init.d/postgrey
chmod 755 /etc/init.d/postgrey &&
  mkdir /var/run/postgrey &&
  chown postgrey:postgrey /var/run/postgrey

# cp PostSRSd Config
cp target/postsrsd/postsrsd /etc/default/postsrsd

# Enables Amavis
cp target/amavis/conf.d/* /etc/amavis/conf.d/
sed -i -r 's/#(@|   \\%)bypass/\1bypass/g' /etc/amavis/conf.d/15-content_filter_mode &&
  adduser clamav amavis &&
  adduser amavis clamav &&
  # no syslog user in debian compared to ubuntu
  adduser --system syslog &&
  useradd -u 5000 -d /home/docker -s /bin/bash -p "$(echo docker | openssl passwd -1 -stdin)" docker &&
  echo "0 4 * * * /usr/local/bin/virus-wiper" | crontab -

# Configure Fail2ban
cp target/fail2ban/jail.conf /etc/fail2ban/jail.conf
cp target/fail2ban/filter.d/dovecot.conf /etc/fail2ban/filter.d/dovecot.conf
echo "ignoreregex =" >>/etc/fail2ban/filter.d/postfix-sasl.conf && mkdir /var/run/fail2ban

# Enables Pyzor and Razor
su - amavis -c "razor-admin -create && razor-admin -register"

# Configure DKIM (opendkim)
# DKIM config files
cp target/opendkim/opendkim.conf /etc/opendkim.conf
cp target/opendkim/default-opendkim /etc/default/opendkim

# Configure DMARC (opendmarc)
cp target/opendmarc/opendmarc.conf /etc/opendmarc.conf
cp target/opendmarc/default-opendmarc /etc/default/opendmarc
cp target/opendmarc/ignore.hosts /etc/opendmarc/ignore.hosts

# Configure fetchmail
cp target/fetchmail/fetchmailrc /etc/fetchmailrc_general
sed -i 's/START_DAEMON=no/START_DAEMON=yes/g' /etc/default/fetchmail
mkdir /var/run/fetchmail && chown fetchmail /var/run/fetchmail

# Configures Postfix
cp target/postfix/main.cf target/postfix/master.cf /etc/postfix/
cp target/postfix/header_checks.pcre target/postfix/sender_header_filter.pcre target/postfix/sender_login_maps.pcre /etc/postfix/maps/
echo "" >/etc/aliases

# Configuring Logs
sed -i -r "/^#?compress/c\compress\ncptruncate" /etc/logrotate.conf &&
  mkdir -p /var/log/mail &&
  chown syslog:root /var/log/mail &&
  touch /var/log/mail/clamav.log &&
  chown -R clamav:root /var/log/mail/clamav.log &&
  touch /var/log/mail/freshclam.log &&
  chown -R clamav:root /var/log/mail/freshclam.log &&
  sed -i -r 's|/var/log/mail|/var/log/mail/mail|g' /etc/rsyslog.conf &&
  sed -i -r 's|;auth,authpriv.none|;mail.none;mail.error;auth,authpriv.none|g' /etc/rsyslog.conf &&
  sed -i -r 's|LogFile /var/log/clamav/|LogFile /var/log/mail/|g' /etc/clamav/clamd.conf &&
  sed -i -r 's|UpdateLogFile /var/log/clamav/|UpdateLogFile /var/log/mail/|g' /etc/clamav/freshclam.conf &&
  sed -i -r 's|/var/log/clamav|/var/log/mail|g' /etc/logrotate.d/clamav-daemon &&
  sed -i -r 's|/var/log/clamav|/var/log/mail|g' /etc/logrotate.d/clamav-freshclam &&
  sed -i -r 's|/var/log/mail|/var/log/mail/mail|g' /etc/logrotate.d/rsyslog &&
  sed -i -r '/\/var\/log\/mail\/mail.log/d' /etc/logrotate.d/rsyslog &&
  # prevent syslog logrotate warnings \
  sed -i -e 's/\(printerror "could not determine current runlevel"\)/#\1/' /usr/sbin/invoke-rc.d &&
  sed -i -e 's/^\(POLICYHELPER=\).*/\1/' /usr/sbin/invoke-rc.d &&
  # prevent email when /sbin/init or init system is not existing \
  sed -i -e 's/invoke-rc.d rsyslog rotate > \/dev\/null/invoke-rc.d rsyslog --quiet rotate > \/dev\/null/g' /etc/logrotate.d/rsyslog

# Get LetsEncrypt signed certificate
curl -s https://letsencrypt.org/certs/lets-encrypt-x3-cross-signed.pem >/etc/ssl/certs/lets-encrypt-x3-cross-signed.pem

cp ./target/bin /usr/local/bin
# Start-mailserver script
cp ./target/helper_functions.sh ./target/check-for-changes.sh ./target/start-mailserver.sh ./target/fail2ban-wrapper.sh ./target/postfix-wrapper.sh ./target/postsrsd-wrapper.sh ./target/docker-configomat/configomat.sh /usr/local/bin/
chmod +x /usr/local/bin/*

# Configure supervisor
cp target/supervisor/supervisord.conf /etc/supervisor/supervisord.conf
cp target/supervisor/conf.d/* /etc/supervisor/conf.d/

cd /

supervisord /etc/supervisor/supervisord.conf
