# frozen_string_literal: true

# Generates a self-signed certificate authority (CA) and uses it to sign certificates
# for OpenSearch nodes and admin users.
#
# Limitations:
# The certificates are not intended to be rotated, to avoid expiration issues they are valid for 100 years.
#
# The node certificate only includes SANs for localhost, hence hostname verification must be disabled, eg:
# plugins.security.ssl.transport.enforce_hostname_verification: false
# plugins.security.ssl.transport.resolve_hostname: false
#
# The goal is to satisfy OpenSearch's security plugin's requirements with minimal complexity.

require "securerandom"
require "openssl"

class OpensearchOperator
  module CertificateGenerator
    Certificates = Struct.new(:ca_key, :ca_crt, :node_key, :node_crt, :admin_key, :admin_crt)

    CA_COMMON_NAME = "opensearch-CA"

    # NOTE: These common names act as magic strings for authorization in config/opensearch.yml
    # via the plugins.security.authcz.admin_dn and plugins.security.nodes_dn settings.
    NODE_COMMON_NAME = "opensearch-node"
    ADMIN_COMMON_NAME = "admin"

    def self.generate
      not_before = Time.now
      not_after = 100.years.from_now

      certificate_authority_key = OpenSSL::PKey::RSA.new(4096)

      certificate_authority_cert = OpenSSL::X509::Certificate.new.tap do |cert|
        cert.version = 2
        cert.serial = SecureRandom.random_number(2**160)
        cert.subject = OpenSSL::X509::Name.new([["CN", CA_COMMON_NAME, OpenSSL::ASN1::UTF8STRING]])
        cert.issuer = cert.subject
        cert.public_key = certificate_authority_key.public_key
        cert.not_before = not_before
        cert.not_after = not_after

        extension_factory = OpenSSL::X509::ExtensionFactory.new
        extension_factory.subject_certificate = cert
        extension_factory.issuer_certificate = cert

        cert.add_extension(extension_factory.create_extension("basicConstraints", "CA:TRUE", true))
        cert.add_extension(extension_factory.create_extension("keyUsage", "keyCertSign, cRLSign", true))
        cert.add_extension(extension_factory.create_extension("subjectKeyIdentifier", "hash", false))
        cert.add_extension(extension_factory.create_extension("authorityKeyIdentifier", "keyid:always,issuer:always", false))
      end

      certificate_authority_cert.sign(certificate_authority_key, OpenSSL::Digest.new("SHA256"))

      node_key = OpenSSL::PKey::RSA.new(2048)
      node_name = OpenSSL::X509::Name.new([["CN", NODE_COMMON_NAME, OpenSSL::ASN1::UTF8STRING]])

      node_csr = OpenSSL::X509::Request.new
      node_csr.version = 0
      node_csr.subject = node_name
      node_csr.public_key = node_key.public_key

      # Add CSR attributes if you want to carry SANs via CSR (not required since we will set them on the cert below)
      node_csr.sign(node_key, OpenSSL::Digest.new("SHA256"))

      node_cert = OpenSSL::X509::Certificate.new.tap do |cert|
        cert.version = 2
        cert.serial = SecureRandom.random_number(2**160)
        cert.subject = node_name
        cert.issuer = certificate_authority_cert.subject
        cert.public_key = node_key.public_key
        cert.not_before = not_before
        cert.not_after = not_after

        extension_factory = OpenSSL::X509::ExtensionFactory.new
        extension_factory.subject_certificate = cert
        extension_factory.issuer_certificate = certificate_authority_cert

        # v3_req equivalent for a server cert
        cert.add_extension(extension_factory.create_extension("basicConstraints", "CA:FALSE", true))
        cert.add_extension(extension_factory.create_extension("keyUsage", "digitalSignature, keyEncipherment", true))
        cert.add_extension(extension_factory.create_extension("extendedKeyUsage", "serverAuth, clientAuth", false))
        cert.add_extension(extension_factory.create_extension("subjectKeyIdentifier", "hash", false))
        cert.add_extension(extension_factory.create_extension("authorityKeyIdentifier", "keyid,issuer", false))

        # Subject Alternative Names (SANs) for localhost
        cert.add_extension(extension_factory.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1", false))
      end

      node_cert.sign(certificate_authority_key, OpenSSL::Digest.new("SHA256"))

      admin_key = OpenSSL::PKey::RSA.new(2048)
      admin_name = OpenSSL::X509::Name.new([["CN", ADMIN_COMMON_NAME, OpenSSL::ASN1::UTF8STRING]])

      admin_csr = OpenSSL::X509::Request.new
      admin_csr.version = 0
      admin_csr.subject = admin_name
      admin_csr.public_key = admin_key.public_key
      admin_csr.sign(admin_key, OpenSSL::Digest.new("SHA256"))

      admin_cert = OpenSSL::X509::Certificate.new.tap do |cert|
        cert.version = 2
        cert.serial = SecureRandom.random_number(2**160)
        cert.subject = admin_name
        cert.issuer = certificate_authority_cert.subject
        cert.public_key = admin_key.public_key
        cert.not_before = not_before
        cert.not_after = not_after

        admin_ext_factory = OpenSSL::X509::ExtensionFactory.new
        admin_ext_factory.subject_certificate = cert
        admin_ext_factory.issuer_certificate = certificate_authority_cert

        # v3_req equivalent for a client cert
        cert.add_extension(admin_ext_factory.create_extension("basicConstraints", "CA:FALSE", true))
        cert.add_extension(admin_ext_factory.create_extension("keyUsage", "digitalSignature, keyEncipherment", true))
        cert.add_extension(admin_ext_factory.create_extension("extendedKeyUsage", "clientAuth", false))
        cert.add_extension(admin_ext_factory.create_extension("subjectKeyIdentifier", "hash", false))
        cert.add_extension(admin_ext_factory.create_extension("authorityKeyIdentifier", "keyid,issuer", false))
      end

      admin_cert.sign(certificate_authority_key, OpenSSL::Digest.new("SHA256"))

      Certificates.new(
        ca_key: certificate_authority_key.to_pem,
        ca_crt: certificate_authority_cert.to_pem,
        node_key: node_key.to_pem,
        node_crt: node_cert.to_pem,
        admin_key: admin_key.to_pem,
        admin_crt: admin_cert.to_pem,
      )
    end
  end
end
