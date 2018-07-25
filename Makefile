GO=env CGO_ENABLED=0 $(shell go env GOPATH)/bin/vgo

# Ensure that the build tools are compiled. Go's caching makes this quick.
$(shell cd build/manifest && $(GO) build -o ../bin/manifest)

# Extract the plugin id from the manifest.
PLUGIN_ID=$(shell build/bin/manifest plugin_id)
ifeq ($(PLUGIN_ID),)
    $(error Cannot parse id from plugin.json)
endif

# Determine if a server is defined in plugin.json
HAS_SERVER=$(shell build/bin/manifest has_server)

# Determine if a webapp is defined in plugin.json
HAS_WEBAPP=$(shell build/bin/manifest has_webapp)

# all, the default target, builds and bundle the plugin.
all: dist

# apply propagates the plugin id into the server/ and webapp/ folders as required.
.PHONY: apply
apply:
	./build/bin/manifest apply

# server builds the server, if it exists, including support for multiple architectures
.PHONY: server
server: 
ifneq ($(HAS_SERVER),)
	mkdir -p server/dist;
	cd server && env GOOS=linux GOARCH=amd64 $(GO) build -o dist/plugin-linux-amd64;
	cd server && env GOOS=darwin GOARCH=amd64 $(GO) build -o dist/plugin-darwin-amd64;
	cd server && env GOOS=windows GOARCH=amd64 $(GO) build -o dist/plugin-windows-amd64.exe;
endif

# webapp/.npminstall ensures NPM dependencies are installed without having to run this all the time
webapp/.npminstall:
ifneq ($(HAS_WEBAPP),)
	cd webapp && npm install
	touch $@
endif

# webapp builds the webapp, if it exists
.PHONY: webapp
webapp: webapp/.npminstall
ifneq ($(HAS_WEBAPP),)
	cd webapp && npm run fix;
	cd webapp && npm run build;
endif

# bundle generates a tar bundle of the plugin for install
.PHONY: bundle
bundle:
	rm -rf dist/
	mkdir -p dist/$(PLUGIN_ID)
	cp plugin.json dist/$(PLUGIN_ID)/
ifneq ($(HAS_SERVER),)
	mkdir -p dist/$(PLUGIN_ID)/server/dist;
	cp -r server/dist/* dist/$(PLUGIN_ID)/server/dist/;
endif
ifneq ($(HAS_WEBAPP),)
	mkdir -p dist/$(PLUGIN_ID)/webapp/dist;
	cp -r webapp/dist/* dist/$(PLUGIN_ID)/webapp/dist/;
endif
	cd dist/$(PLUGIN_ID) && tar -zcvf ../$(PLUGIN_ID).tar.gz *

	@echo plugin built at: dist/$(PLUGIN_ID).tar.gz

# dist builds and bundles the plugin
.PHONY: dist
dist: apply \
      server \
      webapp \
      bundle

# deploy installs the plugin to a (development) server, using the API if appropriate environment
# variables are defined, or copying the files directly to a sibling mattermost-server directory
.PHONY: deploy
deploy:
ifneq ($(and $(MM_SERVICESETTINGS_SITEURL),$(MM_ADMIN_USERNAME),$(MM_ADMIN_PASSWORD)),)
	@echo "Installing plugin via API"
	http --print b --check-status $(MM_SERVICESETTINGS_SITEURL)/api/v4/users/me || ( \
	    TOKEN=`http --print h POST $(MM_SERVICESETTINGS_SITEURL)/api/v4/users/login login_id=$(MM_ADMIN_USERNAME) password=$(MM_ADMIN_PASSWORD) | grep Token | cut -f2 -d' '` && \
	    http --print b GET $(MM_SERVICESETTINGS_SITEURL)/api/v4/users/me Authorization:"Bearer $$TOKEN" \
	)
	http --print b DELETE $(MM_SERVICESETTINGS_SITEURL)/api/v4/plugins/$(PLUGIN_ID)
	http --print b --check-status --form POST $(MM_SERVICESETTINGS_SITEURL)/api/v4/plugins plugin@dist/$(PLUGIN_ID).tar.gz && \
	    http --print b POST $(MM_SERVICESETTINGS_SITEURL)/api/v4/plugins/$(PLUGIN_ID)/enable
else ifneq ($(wildcard ../mattermost-server/.*),)
	@echo "Installing plugin via filesystem. Server restart and manual plugin enabling required"
	mkdir -p ../mattermost-server/plugins/$(PLUGIN_ID)
	tar -C ../mattermost-server/plugins/$(PLUGIN_ID) -zxvf dist/$(PLUGIN_ID).tar.gz
else
	@echo "No supported deployment method available. Install plugin manually."
endif

# clean removes all build artifacts
.PHONY: clean
clean:
	rm -fr dist/
	rm -fr server/dist
	rm -fr webapp/.npminstall
	rm -fr webapp/dist
	rm -fr webapp/node_modules
	rm -fr build/bin/
