Your goal is to implement the syntact programming language as per the references given in @Readme.md you need to implement the language as it his a composable algebraic and consistent piece

You should never implement ad hoc or partial solutions to pass test or to answer the request

## Always work in the algebra

Syntact is one algebra of types (specs/types.md). Everything is implemented as its laws, and nothing beside them. Writing ad hoc code — a special path, a workaround, a second version of a mechanism that exists, a case added where a test fails — is forbidden.

Before writing any code, answer these, and stop if the answer is not clear:

1. Which law of specs/types.md covers this? Where does the kernel implement it?
2. If a case fails, which law is incomplete or wrongly implemented? Fix that law where it is implemented. Never add a path beside it.
3. Does a mechanism for this already exist (Arden, the fold, carving, the lattice, patterns)? Extend it. Never write a second one.
4. If the algebra truly lacks a law, propose its text for specs/types.md to the user first, and code it only once the user agrees.

If what you are writing does not follow from a law, it is ad hoc: stop, go back to the algebra, and start again from the law.

The request that is made to you always refer to that goal of implementing the syntact programming language as per specification

The code is in odin
You should follow best practices
DRY KISS
You should be sure of what you do if in doubt ask the user

Use English in the code even when the conversation is in another language: comments, identifiers, error messages (they are what the LSP shows) and commit messages
