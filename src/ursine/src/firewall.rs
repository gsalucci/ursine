//! Firewall screen: firewalld zones, services and ports.

use crate::prelude::*;
use ursine_api::FirewallStatus;

use crate::package_ui::{text_row, ConfirmVm};

#[derive(Default)]
pub struct FirewallState {
    pub status: Option<FirewallStatus>,
    pub busy: bool,
    pub action_busy: bool,
    pub error: Option<String>,
    pub message: Option<String>,
    pub zone: String,
    pub service: String,
    pub port: String,
    /// Disable confirmation armed (security-sensitive).
    pub pending_disable: bool,
    /// Custom-service delete waiting for confirmation.
    pub pending_delete: Option<String>,
    /// Name input of the "New custom service" form (separate from the
    /// zone-scoped `service` field).
    pub new_service: String,
    /// Custom-service definition port list (`8080/tcp 443/tcp`).
    pub new_service_ports: String,
}

impl FirewallState {
    pub fn apply(&mut self, status: FirewallStatus) {
        if self.zone.is_empty() {
            self.zone.clone_from(&status.default_zone);
        }
        self.status = Some(status);
        self.error = None;
    }

    pub fn view(&self) -> Element<'_, Message> {
        let mut items = vec![ui::header(
            "Firewall",
            (!self.busy && !self.action_busy).then_some(Message::RefreshFirewall),
        )];
        items.extend(ui::status(
            self.error.as_ref(),
            self.message.as_deref(),
            self.busy.then_some("Reading firewalld…"),
            self.action_busy.then_some("Applying firewall change…"),
        ));

        let Some(status) = &self.status else {
            return scrollable(column(items).spacing(16).padding(24)).into();
        };
        if !status.running {
            items.push(
                settings::section()
                    .title("Result")
                    .add(settings::item("State", text("firewalld is not running.")))
                    .into(),
            );
            return scrollable(column(items).spacing(16).padding(24)).into();
        }

        let zones = status
            .zones
            .iter()
            .map(|zone| zone.name.clone())
            .collect::<Vec<_>>();
        let selected = zones.iter().position(|zone| *zone == self.zone);
        let zones_for_zone = zones.clone();
        items.push(
            settings::section()
                .title("Zone setup")
                .add(settings::item(
                    "Filtering",
                    toggler(status.enabled).on_toggle(Message::FirewallEnabledToggled),
                ))
                .add(settings::item(
                    "Default zone",
                    dropdown(
                        zones.clone(),
                        zones.iter().position(|zone| *zone == status.default_zone),
                        Message::FirewallDefaultZoneSelected,
                    ),
                ))
                .add(settings::item(
                    "Selected zone",
                    dropdown(zones, selected, move |index| {
                        Message::FirewallZoneChanged(
                            zones_for_zone.get(index).cloned().unwrap_or_default(),
                        )
                    }),
                ))
                .add(settings::item(
                    "Add service",
                    row(vec![
                        text_input("https", self.service.clone())
                            .on_input(Message::FirewallServiceChanged)
                            .into(),
                        button::text("Open")
                            .on_press_maybe(
                                (!self.action_busy).then_some(Message::FirewallAddService),
                            )
                            .into(),
                    ])
                    .spacing(8),
                ))
                .add(settings::item(
                    "Add port",
                    row(vec![
                        text_input("8080/tcp", self.port.clone())
                            .on_input(Message::FirewallPortChanged)
                            .into(),
                        button::text("Open")
                            .on_press_maybe((!self.action_busy).then_some(Message::FirewallAddPort))
                            .into(),
                    ])
                    .spacing(8),
                ))
                .add(settings::item(
                    "Reload",
                    button::text("Reload firewalld")
                        .on_press_maybe((!self.action_busy).then_some(Message::FirewallReload)),
                ))
                .into(),
        );

        let mut custom = settings::section().title("Custom services");
        if status.custom_services.is_empty() {
            custom = custom.add(settings::item(
                "Definitions",
                text("none (built-in services only)"),
            ));
        }
        for service in &status.custom_services {
            let name = service.clone();
            custom = custom.add(settings::item(
                service.clone(),
                button::text("Delete…").on_press_maybe(
                    (!self.action_busy).then_some(Message::FirewallDeleteService(name)),
                ),
            ));
        }
        custom = custom.add(settings::item(
            "New custom service",
            row(vec![
                text_input("myapp", self.new_service.clone())
                    .on_input(Message::FirewallNewServiceChanged)
                    .into(),
                text_input("ports: 8080/tcp 8443/tcp", self.new_service_ports.clone())
                    .on_input(Message::FirewallPortsChanged)
                    .into(),
                button::text("Create")
                    .on_press_maybe((!self.action_busy).then_some(Message::FirewallCreateService))
                    .into(),
            ])
            .spacing(8),
        ));
        items.push(custom.into());

        for zone in &status.zones {
            let mut section = settings::section().title(format!(
                "{} zone{}",
                zone.name,
                if zone.default { " · default" } else { "" }
            ));
            section = section.add(settings::item(
                "Target",
                text(if zone.target.is_empty() {
                    "unknown".to_string()
                } else {
                    zone.target.clone()
                }),
            ));
            if !zone.interfaces.is_empty() {
                section = section.add(settings::item(
                    "Interfaces",
                    text(zone.interfaces.join(", ")),
                ));
            }
            if zone.services.is_empty() && zone.ports.is_empty() && zone.rich_rules.is_empty() {
                section = section.add(settings::item("Rules", text("none")));
            }
            for rule in &zone.rich_rules {
                section = section.add(settings::item("rich rule", text(rule.clone())));
            }
            for service in &zone.services {
                let zone_name = zone.name.clone();
                let service_name = service.clone();
                section = section.add(settings::item(
                    format!("service {service}"),
                    button::text("Close")
                        .on_press(Message::FirewallRemoveService(zone_name, service_name)),
                ));
            }
            for port in &zone.ports {
                let zone_name = zone.name.clone();
                let port_name = port.clone();
                section = section.add(settings::item(
                    format!("port {port}"),
                    button::text("Close")
                        .on_press(Message::FirewallRemovePort(zone_name, port_name)),
                ));
            }
            items.push(section.into());
        }

        scrollable(column(items).spacing(16).padding(24)).into()
    }
}

impl FirewallState {
    /// Pending disable/delete confirmations as modal data.
    pub(crate) fn pending_confirm(&self) -> Option<ConfirmVm<'_>> {
        if self.pending_disable {
            return Some(ConfirmVm {
                title: "Confirm disable".to_string(),
                rows: vec![(
                    "Consequences".to_string(),
                    text_row(
                        "Stop filtering on the default zone (target ACCEPT)? Traffic the firewall blocked will pass.",
                    ),
                )],
                confirm: Message::FirewallEnabledConfirmed,
                cancel: Message::FirewallEnabledCancelled,
                armed: !self.action_busy,
                destructive: true,
            });
        }
        let name = self.pending_delete.as_ref()?;
        Some(ConfirmVm {
            title: "Confirm delete".to_string(),
            rows: vec![(
                "Consequences".to_string(),
                text_row(format!(
                    "Delete the custom service definition {name}? Zones referencing it lose the service."
                )),
            )],
            confirm: Message::FirewallDeleteConfirmed,
            cancel: Message::FirewallDeleteCancelled,
            armed: !self.action_busy,
            destructive: true,
        })
    }
}
