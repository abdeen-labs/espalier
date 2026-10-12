// The validation and saved values of the provider and model forms.

@testable import AIKit
import Testing

private let existing = BYOKProvider(
    id: "p1",
    name: "Work",
    type: .azure,
    baseUrl: "https://work.openai.azure.com/",
    azureApiVersion: "2024-10-21",
    authKind: .bearer,
    requestTimeoutSeconds: 0.5,
    models: [BYOKModel(id: "gpt-5", name: "GPT-5", reasoningEffort: .high)]
)

/// A form that passes validation when adding a provider.
private func validForm() -> BYOKProviderForm {
    var form = BYOKProviderForm()
    form.name = "OpenAI"
    form.baseUrl = "https://api.openai.com/v1"
    form.secret = "sk-test"
    form.models = [BYOKModel(id: "gpt-4o", name: "GPT-4o")]
    return form
}

@Suite("BYOK provider form")
struct BYOKProviderFormTests {
    @Test("rejects a blank name or URL, a remote http URL, and missing or duplicate models")
    func rejectsInvalidFields() {
        #expect(validateBYOKProviderForm(validForm(), existing: nil) == nil)

        var form = validForm()
        form.name = " \u{A0}\n"
        #expect(validateBYOKProviderForm(form, existing: nil) != nil)

        form = validForm()
        form.baseUrl = "  "
        #expect(validateBYOKProviderForm(form, existing: nil) != nil)
        for url in ["http://api.example.com/v1", "ftp://host", "not a url"] {
            form.baseUrl = url
            #expect(validateBYOKProviderForm(form, existing: nil) != nil, "\(url)")
        }
        form.baseUrl = " http://localhost:11434/v1 "
        #expect(validateBYOKProviderForm(form, existing: nil) == nil)

        form = validForm()
        form.models = [BYOKModel(id: "  ", name: "Blank")]
        #expect(validateBYOKProviderForm(form, existing: nil) != nil)
        form.models = [BYOKModel(id: "a", name: "A"), BYOKModel(id: " b", name: "B"), BYOKModel(id: "b ", name: "B2")]
        #expect(validateBYOKProviderForm(form, existing: nil) != nil)
        // Compared by code units: these are two models.
        form.models = [BYOKModel(id: "caf\u{E9}", name: "1"), BYOKModel(id: "cafe\u{301}", name: "2")]
        #expect(validateBYOKProviderForm(form, existing: nil) == nil)
    }

    @Test("asks for a secret only when the auth kind needs a new one")
    func secrets() {
        var form = validForm()
        form.secret = ""
        #expect(validateBYOKProviderForm(form, existing: nil) != nil)
        form.authKind = .bearer
        #expect(validateBYOKProviderForm(form, existing: nil) != nil)
        form.authKind = .none
        #expect(validateBYOKProviderForm(form, existing: nil) == nil)

        // Editing with the same auth kind keeps the stored secret.
        var editing = BYOKProviderForm(editing: existing)
        #expect(validateBYOKProviderForm(editing, existing: existing) == nil)
        editing.authKind = .apiKey
        #expect(validateBYOKProviderForm(editing, existing: existing) != nil)
    }

    @Test("reads the timeout as JavaScript's Number does, accepting what loading accepts")
    func timeouts() {
        var form = validForm()
        for valid in ["", "  ", "30", " 0.5 ", "1e3", "0x1E", "1e300"] {
            form.requestTimeoutSeconds = valid
            #expect(validateBYOKProviderForm(form, existing: nil) == nil, "\(valid)")
        }
        for invalid in ["0", "-5", "abc", "30s", "Infinity", "1e999", "NaN", "1_000"] {
            form.requestTimeoutSeconds = invalid
            #expect(validateBYOKProviderForm(form, existing: nil) != nil, "\(invalid)")
        }
    }

    @Test("saves trimmed values, keeping the edited provider's ID")
    func savesProviders() {
        var form = validForm()
        form.name = "  OpenAI\n"
        form.baseUrl = " https://api.openai.com/v1 "
        form.wireApi = .responses
        form.azureApiVersion = "ignored"
        form.requestTimeoutSeconds = " 0x1E "
        form.models = [
            BYOKModel(id: " gpt-5 ", name: "  ", reasoningEffort: .low),
            BYOKModel(id: "", name: "No ID"),
            BYOKModel(id: "o3", name: " O3 "),
        ]

        let (added, secret) = makeBYOKProvider(from: form, existing: nil, newID: { "new-id" })

        #expect(
            added
                == BYOKProvider(
                    id: "new-id",
                    name: "OpenAI",
                    type: .openai,
                    baseUrl: "https://api.openai.com/v1",
                    wireApi: .responses,
                    authKind: .apiKey,
                    requestTimeoutSeconds: 30,
                    models: [BYOKModel(id: "gpt-5", name: "gpt-5", reasoningEffort: .low), BYOKModel(id: "o3", name: "O3")]
                )
        )
        #expect(secret == .set("sk-test"))

        // Azure keeps its API version (when not blank) and no API format.
        var azure = BYOKProviderForm(editing: existing)
        azure.azureApiVersion = " 2025-04-01-preview\n"
        azure.requestTimeoutSeconds = ""
        let (edited, unchanged) = makeBYOKProvider(from: azure, existing: existing, newID: { "unused" })
        #expect(edited.id == "p1")
        #expect(edited.wireApi == nil)
        #expect(edited.azureApiVersion == "2025-04-01-preview")
        #expect(edited.requestTimeoutSeconds == nil)
        #expect(unchanged == .keep)
        azure.azureApiVersion = "  "
        #expect(makeBYOKProvider(from: azure, existing: existing).provider.azureApiVersion == nil)

        // Saving the form for a provider, unchanged, keeps the provider and
        // its secret as they were.
        let untouched = makeBYOKProvider(from: BYOKProviderForm(editing: existing), existing: existing)
        #expect(untouched.provider == existing)
        #expect(untouched.secret == .keep)

        // A new provider gets the defaults (OpenAI, Chat Completions, an API
        // key) and a lowercase UUID.
        let fresh = makeBYOKProvider(from: validForm(), existing: nil).provider
        #expect(fresh.type == .openai)
        #expect(fresh.wireApi == .completions)
        #expect(fresh.authKind == .apiKey)
        #expect(fresh.id == fresh.id.lowercased())
        #expect(fresh.id.count == 36)
    }

    @Test("keeps, stores, or removes the secret as desktop does")
    func secretChanges() {
        var form = BYOKProviderForm(editing: existing)
        #expect(makeBYOKProvider(from: form, existing: existing).secret == .keep)
        form.secret = "new-token"
        #expect(makeBYOKProvider(from: form, existing: existing).secret == .set("new-token"))
        form.authKind = .none
        #expect(makeBYOKProvider(from: form, existing: existing).secret == .remove)

        var added = validForm()
        added.secret = ""
        #expect(makeBYOKProvider(from: added, existing: nil).secret == .remove)
    }

    @Test("trims the secret: a pasted key's line break is dropped, and a blank one is none")
    func trimsSecrets() {
        var added = validForm()
        added.secret = " sk-test\n"
        #expect(validateBYOKProviderForm(added, existing: nil) == nil)
        #expect(makeBYOKProvider(from: added, existing: nil).secret == .set("sk-test"))
        added.secret = " \n\t"
        #expect(validateBYOKProviderForm(added, existing: nil) != nil)

        // Editing, a blank secret leaves the stored one alone, unless the
        // auth kind needs a new one.
        var editing = BYOKProviderForm(editing: existing)
        editing.secret = "  \n"
        #expect(validateBYOKProviderForm(editing, existing: existing) == nil)
        #expect(makeBYOKProvider(from: editing, existing: existing).secret == .keep)
        editing.authKind = .apiKey
        #expect(validateBYOKProviderForm(editing, existing: existing) != nil)
        editing.secret = "new-key\r\n"
        #expect(makeBYOKProvider(from: editing, existing: existing).secret == .set("new-key"))
    }

    @Test("never shows the secret when a form or secret change is printed")
    func redactsSecrets() {
        var form = validForm()
        form.secret = "sk-very-secret"
        var dumped = ""
        dump(form, to: &dumped)
        var dumpedChange = ""
        dump(BYOKSecretChange.set("sk-very-secret"), to: &dumpedChange)
        for text in [
            "\(form)", String(reflecting: form), dumped, "\(BYOKSecretChange.set("sk-very-secret"))", dumpedChange,
            String(reflecting: makeBYOKProvider(from: form, existing: nil)),
        ] {
            #expect(!text.contains("sk-very-secret"), "\(text)")
        }
    }
}

@Suite("BYOK model form")
struct BYOKModelFormTests {
    @Test("needs an identifier that no other model of the provider has")
    func validation() {
        var form = BYOKModelForm()
        #expect(validateBYOKModelForm(form, otherModelIds: []) != nil)
        form.id = "  "
        #expect(validateBYOKModelForm(form, otherModelIds: []) != nil)
        form.id = " gpt-4o "
        #expect(validateBYOKModelForm(form, otherModelIds: ["gpt-4o"]) != nil)
        #expect(validateBYOKModelForm(form, otherModelIds: ["gpt-4o-mini"]) == nil)
        form.id = "cafe\u{301}"
        #expect(validateBYOKModelForm(form, otherModelIds: ["caf\u{E9}"]) == nil)
    }

    @Test("lists the other models' trimmed identifiers")
    func otherIds() {
        let models = [BYOKModel(id: " a ", name: "A"), BYOKModel(id: "", name: "Blank"), BYOKModel(id: "b", name: "B")]
        #expect(otherBYOKModelIds(models, excluding: nil) == ["a", "b"])
        #expect(otherBYOKModelIds(models, excluding: 0) == ["b"])
        #expect(otherBYOKModelIds(models, excluding: 2) == ["a"])
    }

    @Test("starts from the model being edited and saves it trimmed, named after its identifier when unnamed")
    func saves() {
        let model = BYOKModel(id: "o3", name: "O3", reasoningEffort: .xhigh)
        var form = BYOKModelForm(editing: model)
        #expect(form == BYOKModelForm(editing: model))
        #expect(makeBYOKModel(from: form) == model)

        form.id = " llama3:latest "
        form.name = " \t"
        form.reasoningEffort = nil
        #expect(makeBYOKModel(from: form) == BYOKModel(id: "llama3:latest", name: "llama3:latest"))
    }
}
