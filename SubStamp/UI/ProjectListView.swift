import SwiftUI

struct ProjectListView: View {
    let onOpenProject: (JobModel) -> Void

    @State private var projects: [ProjectSummary] = []
    @State private var pendingDelete: ProjectSummary?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private let jobStore = JobStore()

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: AppSpacing.m) {
                            ForEach(projects) { project in
                                projectCard(project)
                            }
                        }
                        .padding(AppSpacing.l)
                    }
                }
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(String(localized: "Projects", bundle: .forLocale(locale)))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Close", bundle: .forLocale(locale))) {
                        dismiss()
                    }
                }
            }
        }
        .task {
            reloadProjects()
        }
        .alert(
            Text(String(localized: "Delete Project?", bundle: .forLocale(locale))),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { project in
            Button(String(localized: "Delete", bundle: .forLocale(locale)), role: .destructive) {
                jobStore.deleteJob(id: project.id)
                reloadProjects()
            }
            Button(String(localized: "Cancel", bundle: .forLocale(locale)), role: .cancel) { }
        } message: { _ in
            Text(String(localized: "This will remove the saved project and its local files.", bundle: .forLocale(locale)))
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.m) {
            Image(systemName: "folder")
                .font(.system(size: 42))
                .foregroundStyle(AppColors.secondaryText)

            Text(String(localized: "No saved projects yet.", bundle: .forLocale(locale)))
                .font(AppTypography.bodyEmphasis)
                .foregroundStyle(AppColors.primaryText)

            Text(String(localized: "Save a project after transcription or editing to reopen it later.", bundle: .forLocale(locale)))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.xl)
    }

    private func projectCard(_ project: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack(alignment: .top, spacing: AppSpacing.s) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.displayName)
                        .font(AppTypography.bodyEmphasis)
                        .foregroundStyle(AppColors.primaryText)
                        .lineLimit(2)

                    Text(projectSubtitle(project))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }

                Spacer()

                if !project.videoExists {
                    Text(String(localized: "Video missing", bundle: .forLocale(locale)))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.warning)
                }
            }

            Text(projectDetail(project))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.secondaryText)

            HStack(spacing: AppSpacing.s) {
                Button {
                    onOpenProject(project.job)
                    dismiss()
                } label: {
                    Label(String(localized: "Open", bundle: .forLocale(locale)), systemImage: "folder")
                        .font(AppTypography.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.s)
                        .foregroundStyle(project.videoExists ? Color.white : AppColors.secondaryText)
                        .background(project.videoExists ? AppColors.accent : AppColors.cardBorder)
                        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
                }
                .buttonStyle(.plain)
                .disabled(!project.videoExists)

                Button {
                    pendingDelete = project
                } label: {
                    Label(String(localized: "Delete", bundle: .forLocale(locale)), systemImage: "trash")
                        .font(AppTypography.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.s)
                        .foregroundStyle(AppColors.primaryText)
                        .background(AppColors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius)
                                .stroke(AppColors.cardBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }

    private func projectSubtitle(_ project: ProjectSummary) -> String {
        let audioName = locale.localizedString(forIdentifier: project.job.transcriptionLocale) ?? project.job.transcriptionLocale
        let subtitle1Name = locale.localizedString(forIdentifier: project.job.language1Locale) ?? project.job.language1Locale
        let subtitle2Name: String? = project.job.translationTargetLocale.flatMap {
            locale.localizedString(forIdentifier: $0) ?? $0
        }

        if let subtitle2Name {
            return "\(audioName) -> \(subtitle1Name) + \(subtitle2Name)"
        }
        return "\(audioName) -> \(subtitle1Name)"
    }

    private func projectDetail(_ project: ProjectSummary) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: project.job.updatedAt, relativeTo: Date())
        let cueLabel = String(
            format: String(localized: "%d cues", bundle: .forLocale(locale)),
            project.cueCount
        )
        let status = project.hasTranslatedCues
            ? String(localized: "Translated", bundle: .forLocale(locale))
            : String(localized: "Transcript only", bundle: .forLocale(locale))
        return "\(cueLabel) • \(status) • \(relative)"
    }

    private func reloadProjects() {
        projects = jobStore.loadProjectSummaries()
    }
}
