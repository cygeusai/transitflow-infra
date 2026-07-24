# Transit & Flow — common commands
PROJECT_REF ?= kjooyhvynkzuvsixsutt

.PHONY: help pull-backend new-migration deploy-fn lint

help:
	@echo "make pull-backend      # mirror all migrations + functions from Supabase"
	@echo "make new-migration name=my_change"
	@echo "make deploy-fn name=tf-rent-pay"
	@echo "make lint              # database advisories"

pull-backend:
	./scripts/pull-backend.sh

new-migration:
	supabase migration new $(name)

deploy-fn:
	supabase functions deploy $(name) --project-ref $(PROJECT_REF)

lint:
	supabase db lint --project-ref $(PROJECT_REF)
