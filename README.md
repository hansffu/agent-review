# Emacs Agent Review

Review GitHub pull requests from Emacs!

![](images/overview.png)


## Prepare

### Install

MELPA release pending. Load this package from a local checkout for now.

### Setup github token

This project uses [ghub](https://magit.vc/manual/ghub/Creating-and-Storing-a-Token.html#Creating-and-Storing-a-Token),
see its document for more details about how to setup the token.

Simply put, add the following line to `~/.authinfo` (replace `<...>` accordingly):

```
machine api.github.com login <YOUR_USERNAME>^agent-review password <YOUR_GITHUB_PERSONAL_TOKEN>
```

You may customize username and api host (for github enterprise instances) using [ghub](https://magit.vc/manual/ghub/Github-Configuration-Variables.html#Github-Configuration-Variables),
or you can also set `agent-review-ghub-username` and `agent-review-ghub-host` for agent review only.

<details>
  <summary>For github enterprise users</summary>
  
The detailed setup for different github enterprise sites may vary. Just for reference:
  
  1. set agent-review-ghub-host to "github.corp.my-company.com/api/v3"
  2. set agent-review-ghub-username
  3. in ~/.authinfo, use `machine github.corp.my-company.com/api/v3 login my-username^agent-review password ghp_xxxxxxxxxxxx`

</details>

## Usage

This package provides the following entrypoint:

- `M-x agent-review`: open a PR with given URL.
- `M-x agent-review-notification`: list github notifications in a buffer, and open PRs from it
- `M-x agent-review-search-open`: search in github and select a PR from search result.
- `M-x agent-review-search`: like above, but list results in a buffer

Suggested config (especially for evil users):

```elisp
(evil-ex-define-cmd "prr" #'agent-review)
(evil-ex-define-cmd "prs" #'agent-review-search)
(evil-ex-define-cmd "prn" #'agent-review-notification)
(add-to-list 'browse-url-default-handlers
             '(agent-review-url-parse . agent-review-open-url))
```

Personally I suggest two possible workflows:

1. Use `agent-review-notification` as your "dashboard" and enter agent review from it.
2. Use [notmuch](https://notmuchmail.org/notmuch-emacs/) (or some other email client in emacs) to
receive and read all GitHub notification emails and start `agent-review` from the notmuch message buffer.
Running `agent-review` in the email buffer will automatically find the PR url in the email.


### Keybindings in Agent Review buffer

There's three most-used keybindings:

- `C-c C-c`: add a comment based on current context.
  - When current point is on a review thread, add a comment to current thread;
  - When current point in on the changed files, add a pending review thread to current changed line; you can also add it to multiple lines by selecting a region;
  - Otherwise, add a comment to the pull request.
- `C-c C-s`: perform some "action" based on current context.
  - When current point is on a review thread, resolve current thread;
  - When current point is on the changed files, or there are any pending reviews, prompt to submit the review with action;
  - Otherwise, prompt to merge, close or re-open the PR.
- `C-c C-e`: edit the content under point based on current context, the following items can be updated (if you have the right permission):
  - PR description
  - PR title
  - Comment
  - Comment in a review thread
  - Pending review thread

There's also buttons (clickable texts) for major actions (e.g. reply, submit review), you can just use them.

Some other keybindings or commands:

- `C-c C-r`: refresh (reload) current buffer
- `C-c C-v`: view current changed file under point (either HEAD or BASE version, based on current point) in a separated buffer
- `C-c C-o`: open this pull request in browser
- `C-c C-q`: request reviewers
- `C-c C-l`: set labels
- `C-c C-j`: set reactions (emojis) for comment or description under current point
- `C-c C-f`: view current file; invoke with `C-u` prefix to select head or base
- `C-c C-d`: open current diff; invoke with `C-u` prefix to select file
- `M-x agent-review-select-commit`: select only some commits for review

Evil users will also find some familiar keybindings. See `describe-mode` for more details.

### Keybindings in Agent Review Input buffer

When you are adding or editing the comment, you will be editing in a new Agent Review Input buffer.
Keybindings in this buffer:

- `C-c C-c`: Finish editing, confirm the content
- `C-c C-k`: Abort, drop the content
- `C-c @`: Mention some other (inserting `@username`)

Recommend using (company-emoji)[https://github.com/dunn/company-emoji] to insert emojis in Agent Review Input buffer.

### Keybindings in Agent Review Notification buffer

- `RET`: Open the PR (While this buffer lists all types of notifications, only Pull Requests can be opened by this package)
- `C-c C-n` / `C-c C-p` (`gj` / `gk` for evil users): next/prev page
- Refresh with `revert-buffer` (`gr` for evil users)
- `C-c C-t`: toggle filters

Actions in this buffer works like `dired`: items are first marked, then executed:

- `C-c C-r` (`r` for evil users): mark as read. Note that items are automatically marked as read when opened.
- `C-c C-d` (`d` for evil users): mark as unsubscribe (delete).
- `C-c C-s` (`x` for evil users): execute marks
- `C-c C-u` (`u` for evil users): unmark item
