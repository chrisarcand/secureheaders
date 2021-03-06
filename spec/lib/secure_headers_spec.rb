require 'spec_helper'

module SecureHeaders
  describe SecureHeaders do
    example_hpkp_config = {
      max_age: 1_000_000,
      include_subdomains: true,
      report_uri: '//example.com/uri-directive',
      pins: [
        { sha256: 'abc' },
        { sha256: '123' }
      ]
    }

    example_hpkp_config_value = %(max-age=1000000; pin-sha256="abc"; pin-sha256="123"; report-uri="//example.com/uri-directive"; includeSubDomains)

    before(:each) do
      reset_config
      @request = Rack::Request.new("HTTP_X_FORWARDED_SSL" => "on")
    end

    it "raises a NotYetConfiguredError if default has not been set" do
      expect do
        SecureHeaders.header_hash_for(@request)
      end.to raise_error(Configuration::NotYetConfiguredError)
    end

    it "raises a NotYetConfiguredError if trying to opt-out of unconfigured headers" do
      expect do
        SecureHeaders.opt_out_of_header(@request, CSP::CONFIG_KEY)
      end.to raise_error(Configuration::NotYetConfiguredError)
    end

    describe "#header_hash_for" do
      it "allows you to opt out of individual headers" do
        Configuration.default
        SecureHeaders.opt_out_of_header(@request, CSP::CONFIG_KEY)
        hash = SecureHeaders.header_hash_for(@request)
        expect(hash['Content-Security-Policy-Report-Only']).to be_nil
        expect(hash['Content-Security-Policy']).to be_nil
      end

      it "allows you to opt out entirely" do
        Configuration.default
        SecureHeaders.opt_out_of_all_protection(@request)
        hash = SecureHeaders.header_hash_for(@request)
        ALL_HEADER_CLASSES.each do |klass|
          expect(hash[klass::CONFIG_KEY]).to be_nil
        end
      end

      it "allows you to override X-Frame-Options settings" do
        Configuration.default
        SecureHeaders.override_x_frame_options(@request, XFrameOptions::DENY)
        hash = SecureHeaders.header_hash_for(@request)
        expect(hash[XFrameOptions::HEADER_NAME]).to eq(XFrameOptions::DENY)
      end

      it "allows you to override opting out" do
        Configuration.default do |config|
          config.x_frame_options = OPT_OUT
          config.csp = OPT_OUT
        end

        SecureHeaders.override_x_frame_options(@request, XFrameOptions::SAMEORIGIN)
        SecureHeaders.override_content_security_policy_directives(@request, default_src: %w(https:), script_src: %w('self'))

        hash = SecureHeaders.header_hash_for(@request)
        expect(hash[CSP::HEADER_NAME]).to eq("default-src https:; script-src 'self'")
        expect(hash[XFrameOptions::HEADER_NAME]).to eq(XFrameOptions::SAMEORIGIN)
      end

      it "produces a hash of headers with default config" do
        Configuration.default
        hash = SecureHeaders.header_hash_for(@request)
        expect_default_values(hash)
      end

      it "does not set the HSTS header if request is over HTTP" do
        plaintext_request = Rack::Request.new({})
        Configuration.default do |config|
          config.hsts = "max-age=123456"
        end
        expect(SecureHeaders.header_hash_for(plaintext_request)[StrictTransportSecurity::HEADER_NAME]).to be_nil
      end

      it "does not set the HPKP header if request is over HTTP" do
        plaintext_request = Rack::Request.new({})
        Configuration.default do |config|
          config.hpkp = example_hpkp_config
        end

        expect(SecureHeaders.header_hash_for(plaintext_request)[PublicKeyPins::HEADER_NAME]).to be_nil
      end

      context "content security policy" do
        it "appends a value to csp directive" do
          Configuration.default do |config|
            config.csp = {
              default_src: %w('self'),
              script_src: %w(mycdn.com 'unsafe-inline')
            }
          end

          SecureHeaders.append_content_security_policy_directives(@request, script_src: %w(anothercdn.com))
          hash = SecureHeaders.header_hash_for(@request)
          expect(hash[CSP::HEADER_NAME]).to eq("default-src 'self'; script-src mycdn.com 'unsafe-inline' anothercdn.com")
        end

        it "overrides individual directives" do
          Configuration.default do |config|
            config.csp = {
              default_src: %w('self')
            }
          end
          SecureHeaders.override_content_security_policy_directives(@request, default_src: %w('none'))
          hash = SecureHeaders.header_hash_for(@request)
          expect(hash[CSP::HEADER_NAME]).to eq("default-src 'none'")
        end

        it "overrides non-existant directives" do
          Configuration.default
          SecureHeaders.override_content_security_policy_directives(@request, img_src: [ContentSecurityPolicy::DATA_PROTOCOL])
          hash = SecureHeaders.header_hash_for(@request)
          expect(hash[CSP::HEADER_NAME]).to eq("default-src https:; img-src data:")
        end

        it "does not append a nonce when the browser does not support it" do
          Configuration.default do |config|
            config.csp = {
              default_src: %w('self'),
              script_src: %w(mycdn.com 'unsafe-inline'),
              style_src: %w('self')
            }
          end

          request = Rack::Request.new(@request.env.merge("HTTP_USER_AGENT" => USER_AGENTS[:safari5]))
          nonce = SecureHeaders.content_security_policy_script_nonce(request)
          hash = SecureHeaders.header_hash_for(request)
          expect(hash[CSP::HEADER_NAME]).to eq("default-src 'self'; script-src mycdn.com 'unsafe-inline'; style-src 'self'")
        end

        it "appends a nonce to the script-src when used" do
          Configuration.default do |config|
            config.csp = {
              default_src: %w('self'),
              script_src: %w(mycdn.com),
              style_src: %w('self')
            }
          end

          request = Rack::Request.new(@request.env.merge("HTTP_USER_AGENT" => USER_AGENTS[:chrome]))
          nonce = SecureHeaders.content_security_policy_script_nonce(request)

          # simulate the nonce being used multiple times in a request:
          SecureHeaders.content_security_policy_script_nonce(request)
          SecureHeaders.content_security_policy_script_nonce(request)
          SecureHeaders.content_security_policy_script_nonce(request)

          hash = SecureHeaders.header_hash_for(request)
          expect(hash['Content-Security-Policy']).to eq("default-src 'self'; script-src mycdn.com 'nonce-#{nonce}'; style-src 'self'")
        end
      end
    end

    context "validation" do
      it "validates your hsts config upon configuration" do
        expect do
          Configuration.default do |config|
            config.hsts = 'lol'
          end
        end.to raise_error(STSConfigError)
      end

      it "validates your csp config upon configuration" do
        expect do
          Configuration.default do |config|
            config.csp = { CSP::DEFAULT_SRC => '123456' }
          end
        end.to raise_error(ContentSecurityPolicyConfigError)
      end

      it "raises errors for unknown directives" do
        expect do
          Configuration.default do |config|
            config.csp = { made_up_directive: '123456' }
          end
        end.to raise_error(ContentSecurityPolicyConfigError)
      end

      it "validates your xfo config upon configuration" do
        expect do
          Configuration.default do |config|
            config.x_frame_options = "NOPE"
          end
        end.to raise_error(XFOConfigError)
      end

      it "validates your xcto config upon configuration" do
        expect do
          Configuration.default do |config|
            config.x_content_type_options = "lol"
          end
        end.to raise_error(XContentTypeOptionsConfigError)
      end

      it "validates your x_xss config upon configuration" do
        expect do
          Configuration.default do |config|
            config.x_xss_protection = "lol"
          end
        end.to raise_error(XXssProtectionConfigError)
      end

      it "validates your xdo config upon configuration" do
        expect do
          Configuration.default do |config|
            config.x_download_options = "lol"
          end
        end.to raise_error(XDOConfigError)
      end

      it "validates your x_permitted_cross_domain_policies config upon configuration" do
        expect do
          Configuration.default do |config|
            config.x_permitted_cross_domain_policies = "lol"
          end
        end.to raise_error(XPCDPConfigError)
      end

      it "validates your hpkp config upon configuration" do
        expect do
          Configuration.default do |config|
            config.hpkp = "lol"
          end
        end.to raise_error(PublicKeyPinsConfigError)
      end
    end
  end
end
