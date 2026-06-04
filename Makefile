# Florence's Seismic Travel Bureau — convenience targets.
# Most are thin wrappers; everything works without make too (see README).

PORT ?= 8080

.PHONY: help run install uninstall kiosk docker docker-down health logs

help:
	@echo "Florence's Seismic Travel Bureau"
	@echo "  make run        run the server locally on :$(PORT)  (Ctrl-C to stop)"
	@echo "  make install    install + enable the systemd service (uses sudo)"
	@echo "  make uninstall  remove the systemd service"
	@echo "  make kiosk      configure this Pi as a full-screen kiosk"
	@echo "  make docker     build + run via docker compose"
	@echo "  make docker-down stop the docker stack"
	@echo "  make health     curl the /healthz endpoint"
	@echo "  make logs       follow the service logs (journalctl)"

run:
	FLORENCE_PORT=$(PORT) python3 server.py

install:
	sudo env PORT=$(PORT) ./deploy/install.sh

uninstall:
	sudo ./deploy/install.sh --uninstall

kiosk:
	./deploy/kiosk-setup.sh "http://localhost:$(PORT)/?kiosk=1"

docker:
	docker compose up -d --build

docker-down:
	docker compose down

health:
	@curl -fsS "http://localhost:$(PORT)/healthz" | python3 -m json.tool

logs:
	journalctl -u florence-tracker -f
