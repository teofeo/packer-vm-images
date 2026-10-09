# Construction locale des images Packer.
# Usage : make build IMAGE=debian-13
#         make tag IMAGE=debian-13 VERSION=v1.0.0

PACKER    ?= packer
IMAGE     ?= debian-13
IMAGE_DIR := images/$(IMAGE)

.DEFAULT_GOAL := help
.PHONY: help init fmt validate build clean tag check-image

help: ## Affiche cette aide
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "} {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@echo "Images disponibles : $(notdir $(wildcard images/*))"

check-image:
	@test -d "$(IMAGE_DIR)" || { echo "Image inconnue : $(IMAGE) ($(IMAGE_DIR) introuvable)" >&2; exit 1; }

init: check-image ## Installe les plugins Packer de l'image
	$(PACKER) init $(IMAGE_DIR)

fmt: ## Formate tous les fichiers HCL
	$(PACKER) fmt -recursive images

validate: init ## Vérifie le formatage et valide la configuration de l'image
	$(PACKER) fmt -check -diff -recursive $(IMAGE_DIR)
	$(PACKER) validate $(IMAGE_DIR)

build: init ## Construit l'image (output/$(IMAGE)/$(IMAGE).qcow2)
	$(PACKER) build -force $(IMAGE_DIR)

clean: ## Supprime les images produites et le cache Packer
	rm -rf output packer_cache

tag: check-image ## Crée le tag de release local <image>/<version> (VERSION=vX.Y.Z)
	@echo "$(VERSION)" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "VERSION doit être au format vX.Y.Z (ex. make tag IMAGE=$(IMAGE) VERSION=v1.0.0)" >&2; exit 1; }
	git tag -a "$(IMAGE)/$(VERSION)" -m "$(IMAGE) $(VERSION)"
	@echo "Tag $(IMAGE)/$(VERSION) créé. Pour publier : git push origin $(IMAGE)/$(VERSION)"
