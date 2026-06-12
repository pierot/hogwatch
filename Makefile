.PHONY: build release

build:
	./build.sh

# Tag a new version and push it; GitHub Actions builds and publishes the release.
release:
	@if ! git diff-index --quiet HEAD --; then echo "Working tree is dirty; commit first."; exit 1; fi
	@last=$$(git tag --sort=-v:refname | head -1); \
	if [ -z "$$last" ]; then \
		new="v1.0"; \
		printf "No previous release. Create %s? [y/N] " "$$new"; \
		read -r ok; [ "$$ok" = "y" ] || { echo "Aborted."; exit 1; }; \
	else \
		ver=$${last#v}; major=$${ver%%.*}; minor=$${ver#*.}; \
		small="v$$major.$$((minor+1))"; big="v$$((major+1)).0"; \
		printf "Latest release: %s\nBump small (%s) or big (%s)? [s/b] " "$$last" "$$small" "$$big"; \
		read -r choice; \
		case "$$choice" in \
			s) new="$$small";; \
			b) new="$$big";; \
			*) echo "Aborted."; exit 1;; \
		esac; \
	fi; \
	git tag "$$new" && git push origin main "$$new" && \
	echo "Pushed $$new — release builds at https://github.com/pierot/hogwatch/actions"
