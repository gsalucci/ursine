//! Services screen: init service status and lifecycle (`OpenRC` and dinit).

use crate::prelude::*;
use ursine_api::{Service, ServiceOp};

use crate::package_ui::{text_row, ConfirmVm};

#[derive(Default)]
pub struct ServicesState {
    pub services: Vec<Service>,
    pub busy: bool,
    pub action_busy: bool,
    pub error: Option<String>,
    pub message: Option<String>,
    pub pending: Option<(String, ServiceOp)>,
}

impl ServicesState {
    pub fn apply(&mut self, services: Vec<Service>) {
        self.services = services;
        self.error = None;
    }

    pub fn view(&self) -> Element<'_, Message> {
        let mut items = vec![ui::header(
            "Services",
            (!self.busy && !self.action_busy).then_some(Message::RefreshServices),
        )];
        items.extend(ui::status(
            self.error.as_ref(),
            self.message.as_deref(),
            self.busy.then_some("Reading services…"),
            self.action_busy.then_some("Running service action…"),
        ));

        let init = if self.services.iter().any(|service| service.init == "dinit") {
            "dinit"
        } else if self.services.iter().any(|service| service.init == "openrc") {
            "OpenRC"
        } else {
            "Services"
        };
        let mut list =
            settings::section().title(format!("{init} services ({})", self.services.len()));
        if self.services.is_empty() {
            list = list.add(settings::item("Result", text("No services reported.")));
        }
        for service in &self.services {
            let name = service.name.clone();
            let started = service.state == "started";
            list = list.add(settings::item(
                format!(
                    "{} — {}{}",
                    service.name,
                    service.state,
                    if service.enabled { " · enabled" } else { "" }
                ),
                column(vec![row(vec![
                    button::text(if started { "Stop" } else { "Start" })
                        .on_press(Message::ServiceRequested(
                            name.clone(),
                            if started {
                                ServiceOp::Stop
                            } else {
                                ServiceOp::Start
                            },
                        ))
                        .into(),
                    button::text("Restart")
                        .on_press(Message::ServiceRequested(name.clone(), ServiceOp::Restart))
                        .into(),
                    button::text(if service.enabled { "Disable" } else { "Enable" })
                        .on_press(Message::ServiceRequested(
                            name.clone(),
                            if service.enabled {
                                ServiceOp::Disable
                            } else {
                                ServiceOp::Enable
                            },
                        ))
                        .into(),
                ])
                .spacing(8)
                .into()])
                .spacing(4),
            ));
        }
        items.push(list.into());

        scrollable(column(items).spacing(16).padding(24)).into()
    }
}

impl ServicesState {
    /// Pending service-operation confirmation as modal data.
    pub(crate) fn pending_confirm(&self) -> Option<ConfirmVm<'_>> {
        let (name, op) = self.pending.as_ref()?;
        Some(ConfirmVm {
            title: format!("Confirm {op:?}"),
            rows: vec![(
                "Consequences".to_string(),
                text_row(format!("Apply {op:?} to service {name}?")),
            )],
            confirm: Message::ServiceConfirmed,
            cancel: Message::ServiceCancelled,
            armed: !self.action_busy,
            destructive: true,
        })
    }
}
