# Transit & Flow — common commands
PROJECT_REF ?= kjooyhvynkzuvsixsutt

.PHONY: help pull-backend new-migration deploy-fn lint verify verify-jwt verify-jwt-live plan-jwt

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

# Everything CI checks without credentials. Run this before you push; it is the
# same set, in the same order, so a green here is a green there.
verify:
	python3 scripts/test_verify_migration_manifest.py
	python3 scripts/verify_migration_manifest.py
	python3 scripts/verify_verify_jwt.py

verify-jwt:
	python3 scripts/verify_verify_jwt.py

# Needs SUPABASE_ACCESS_TOKEN in the environment. Read-only.
verify-jwt-live:
	python3 scripts/verify_verify_jwt.py --live --require-live

plan-jwt:
	python3 scripts/verify_verify_jwt.py --live --plan
