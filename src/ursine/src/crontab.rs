//! Crontab screen (SPEC-crontab): view and replace the session user's
//! crontab; works with busybox, cronie and vixie/Debian via `crontab`.

use crate::prelude::*;
use cosmic::widget::text_editor::{self, text_editor};

use crate::package_ui::{text_row, ConfirmVm};

#[derive(Debug, Default)]
pub struct CrontabState {
    pub busy: bool,
    pub action_busy: bool,
    /// The get request finished at least once.
    pub loaded: bool,
    /// A crontab existed when loaded (vs "none yet").
    pub had_crontab: bool,
    /// Editor buffer (source of truth; synced on every edit action).
    pub editor: text_editor::Content<cosmic::Renderer>,
    /// Plain text of the editor (what Save sends).
    pub body: String,
    /// Save confirmation step (writes happen behind confirm).
    pub confirm: bool,
    pub error: Option<String>,
    pub message: Option<String>,
}

impl CrontabState {
    pub fn view(&self) -> Element<'_, Message> {
        let mut items = vec![ui::header(
            "Crontab",
            (!self.busy && !self.action_busy).then_some(Message::OpenCrontab),
        )];
        items.extend(ui::status(
            self.error.as_ref(),
            self.message.as_deref(),
            self.busy.then_some("Reading crontab…"),
            self.action_busy.then_some("Saving crontab…"),
        ));

        if !self.loaded {
            if !self.busy {
                items.push(text("Crontab could not be loaded.").into());
            }
            return scrollable(column(items).spacing(16).padding(24)).into();
        }
        if !self.had_crontab && self.body.trim().is_empty() {
            items.push(text("No crontab yet for this user — write one below.").into());
        }

        items.push(
            text_editor(&self.editor)
                .on_action(|_action| Message::CrontabEdited)
                .height(Length::Fixed(360.0))
                .into(),
        );

        if !self.confirm {
            items.push(
                button::suggested("Save crontab")
                    .on_press_maybe(
                        (!self.busy && !self.action_busy).then_some(Message::CrontabSaveRequested),
                    )
                    .into(),
            );
            items.push(
                text("Applied through the system `crontab` tool (busybox, cronie and Debian all work).")
                    .into(),
            );
        }

        scrollable(column(items).spacing(16).padding(24)).into()
    }
}

impl CrontabState {
    /// Pending save confirmation as modal data.
    pub(crate) fn pending_confirm(&self) -> Option<ConfirmVm<'_>> {
        self.confirm.then(|| ConfirmVm {
            title: "Confirm save".to_string(),
            rows: vec![(
                "Consequences".to_string(),
                text_row("Replace the crontab with the editor content? An empty body clears it."),
            )],
            confirm: Message::CrontabSaveConfirmed,
            cancel: Message::CrontabSaveCancelled,
            armed: !self.action_busy && !self.busy,
            destructive: false,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_defaults_to_empty_editor() {
        let state = CrontabState::default();
        assert!(!state.loaded);
        assert!(!state.confirm);
        assert!(state.body.is_empty());
        let _ = state.view();
    }

    #[test]
    fn view_renders_loaded_and_confirm_states() {
        let mut state = CrontabState {
            loaded: true,
            had_crontab: true,
            body: "* * * * * true\n".into(),
            editor: text_editor::Content::new(),
            ..CrontabState::default()
        };
        let _ = state.view();
        state.confirm = true;
        let _ = state.view();
        state.error = Some("boom".into());
        state.message = Some("saved".into());
        let _ = state.view();
    }
}
