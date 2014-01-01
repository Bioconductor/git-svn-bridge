<a name="top"></a>

*This page is under construction. It will eventually move to the
Bioconductor web site.*

# Using the Bioconductor Git-SVN bridge


The Git-SVN Bridge allows Github repositories to be in sync with the 
Bioconductor Subversion (SVN) repository.
Once you have created a bridge, you don't need to use Subversion again. 
Using a bridge also enables 
social coding features of Github such as issue tracking and pull requests.

## How to create a bridge

In order to create a bridge, you must be the maintainer of a Bioconductor 
package, with read/write access to its directory in the
Bioconductor
[Subversion repository](http://localhost:3000/developers/how-to/source-control/).

You will also need to create a Github repository which will mirror
the Subversion repository. If you already have a Github repository that has 
files in it, that will work too.

Let's assume that your package is called `MyPackage`, your Subversion
username is `j.user`, your Github username is `username`, and your email 
address is `juser@contributor.org`.

Your package will be in Subversion at the URL

    https://hedgehog.fhcrc.org/bioconductor/trunk/madman/Rpacks/MyPackage

That's the URL for the devel version of the package. You can also create a bridge to the release version of a package (see the
[FAQ](#bridge-to-release-version)).

<a name="step1"></a>
## Step 1: Configure your Github Repository

If you haven't already created a Github repository, please
[do so now](#create-github). Open the repository page in a web browser;
it will have a URL like:

    https://github.com/yourusername/MyPackage

If you are working with a repository that is part of an organization,
see the [FAQ](#org-repos).

Click on the "Settings" link in the right-side nav bar.
It will look like this:

<img src="settings.jpg"/>

Under **Options** in the left-hand nav bar, click "Collaborators".
At this point, you may be asked to enter your Github password. Do so.
Then in the "Add a Friend" box, type 

    bioc-sync

Then click the **Add** button. This allows the Git-SVN bridge to make changes to your github repository in response to Subversion commits.

Again in the nav bar at left, click on "Service Hooks".
Then click on "WebHook URLs". (there may be a number next to the link).
In the URL box, enter:

    http://git-svn.bioconductor.org/git-push-hook

**Important Note**: This url must start with `http`, **not** `https`.

Then click the **Update Settings** button.
This step lets Bioconductor know when there has been a push to 
your Github repository.


**Important Note**: *Both of the above steps **must** be done 
or your Git-SVN bridge will **not** function properly.*

## Step 2: Create the bridge

Open a browser window pointing to 
the [Git-SVN bridge web application](https://gitsvn.bioconductor.org).

In the bridge web app, click 
"[Log In](https://gitsvn.bioconductor.org/login)".

Log in with your SVN Username, SVN password and email address.
See the [FAQ](#svn-password) if you don't remember either of these.

Once you've logged in, click the 
[Create New Github-SVN mapping](https://gitsvn.bioconductor.org/newproject)
link.

Choose the *root* directory path. If you are creating a bridge
for a software package in Bioconductor's `devel` branch, use
the default value of this dropdown 
(`https://hedgehog.fhcrc.org/bioconductor/trunk/madman/Rpacks/`).

For *Directory Name*, choose the name of your package, e.g.
`MyPackage`.

In the next box, enter the URL for the Github repository you created
in [step 1](#step1), e.g.

    https://github.com/username/MyPackage

Decide how you want to handle initial merge conflicts. 
If you are starting with a **completely** empty Github repository
(which does not even have a README file in it), then it does not matter
how you answer this question.

If both your Subversion and your Github repositories have contents, 
decide **carefully** how you want to proceed:

* Choosing "SVN wins unconditionally" means that the contents of
  your SVN repository will completely overwrite the contents of
  your github repository. You will not have the opportunity
  to manually merge conflicting files. You will still have access
  to files that were changed, via git's commit history.

* Choosing "Git wins unconditionally" means the opposite--the contents
  of your Github repository will completely overwrite the contents
  of your SVN repository, and this will then **propagate to the
  Bioconductor build system**. You will have access to files
  that were changed, but only via svn.

You now need to check two boxes: the first confirms that you have 
configured your Github repository as described in [Step 1](#step1),
the second that you will respond to pull requests and issues
filed in your Github repository (see the [FAQ](#responsibilities)).

You may now click the **Create New Project** button.

You should see a message that your bridge was created successfully.
You can click [My Bridges](https://gitsvn.bioconductor.org/my_bridges)
to confirm this.

## Step 3: What now?

Any commits made to your package in Subversion will be mirrored
in the *master* branch of your Github repository.

Any pushes to the *master* branch of your Github repository will
automatically be mirrored in Subversion, and will propagate
to the [Bioconductor Build System](http://bioconductor.org/checkResults/).

The Git-SVN bridge only affects the *master* branch of your Github
repository. It will ignore changes made in any other branch, even
if those branches are pushed to Github.
So you are free to experiment and even break your package
as long as you don't do it in the *master* branch.

## FAQ

<a name="history"></a>
##### Can I see old commit history?

After creating a bridge, you can't see old svn commit information
from prior to bridge creation if you're using git. (You can still see it 
with svn).

Conversely, in svn, you can't see Git commit messages from
before the bridge was created. You can still see them in git.

Once the bridge is created, you'll see subsequent commit messages
from both git and svn, whether you are using git or svn.

This may change in the future.

[[Back To Top]](#top)

<a name="commit-messages"></a>
##### How do I know whether a commit came from Git or SVN?

If a commit was made in svn, it will show up in the output
of `git log` as something like this:

    commit f0c494108cc854a7a7a267c6a40ea8a3bdef2209
    Author: j.user <j.user@bc3139a8-67e5-0310-9ffc-ced21a209358>
    Date:   Tue Dec 24 19:12:36 2013 +0000

        This is my commit message.
        
        git-svn-id: https://hedgehog.fhcrc.org/bioconductor/trunk/madman/Rpacks/MyPackage0@85102 bc3139a8-67e5-0310-9ffc-ced21a209358

The `git-svn-id` tells you that this commit originated in svn,
and the number after the `@` is the SVN revision number.

If you are working in Subversion, a commit made in git will look 
something like this when you run `svn log -v`:

    ------------------------------------------------------------------------
    r85104 | j.user | 2013-12-24 11:13:59 -0800 (Tue, 24 Dec 2013) | 12 lines
    Changed paths:
       M /trunk/madman/Rpacks/MyPackage/DESCRIPTION

    Commit made by the git-svn bridge at https://gitsvn.bioconductor.org.
    Consists of 1 commit(s).

    Commit information:

        Commit id: 6132d20eb3615afdeafcb8a086e952e4b9f8977f
        Commit message:
        Bumped the version number
        Committed by Jill User <juser at contributor.org>
        Commit date: 2013-12-24T11:13:49-08:00

Note that the svn user who did the commit will always be
the user you were logged in as when you created the bridge
in [Step 2](#step2). 

The name of the Git user (denoted by the `Committed by` line)
might vary, if you have granted other users "push" access to
your repository, or if you accept a pull request.



[[Back To Top]](#top)


<a name="other-users-push"></a>
##### Other users have push access to my repository. Will it work for them?

Yes. Be sure this is what you want. If you grant another user push access to your repository, they can push to any branch, including master, which will then propagate to the Bioconductor build system. If you don't want the user to have that level of access, then don't grant them push access. You can accept pull requests from them instead.

The Git-SVN bridge will correctly record the name of the git user
who made the commits (see above [FAQ](#commit-messages)).


[[Back To Top]](#top)


<a name="howto-list-bridges"></a>
##### How do I know what Git-SVN bridges exist?

Look at the 
[list of bridges](https://gitsvn.bioconductor.org/list_bridges)
maintained by the web app.

[[Back To Top]](#top)

##### How do I advertise my bridge?

Add the Github URL of your repository to the URL: field 
in the DESCRIPTION file of your package. You can also 
mention your bridge on the bioc-devel 
[mailing list](http://bioconductor.org/help/mailing-list/).

[[Back To Top]](#top)

##### I want to contribute to a package using Github, but there is no bridge for it.

You can request that the maintainer of the package create a bridge,
but if they do not wish to do so, you'll need to contribute
via other means. If a maintainer will not review pull requests and issues
filed via Github, then it is pointless to file them.


<a name="responsibilities"></a>
##### What are my responsibilities when I create a bridge?

As implied by the above question, package maintainers must
respond to pull requests and issues filed in their Github 

[[Back To Top]](#top)



<a name="svn-password"></a>
##### I don't know my Subversion username and/or password. What do I do?

[[Back To Top]](#top)

<a name="create-github"></a>
##### How do I create a Github repository?

[[Back To Top]](#top)

<a name="bridge-to-release-version"></a>
##### How do I create a bridge to the release version of my package?

[[Back To Top]](#top)

<a name="org-repos"></a>
##### Working with a Github Organization repository

[[Back To Top]](#top)



##### I don't want to use the bridge, I want to keep my repositories in sync manually.

You can do that by following
[these guidelines](https://github.com/Bioconductor/BiocGithubHelp/wiki/Managing-your-Bioc-code-on-hedgehog-and-github).

[[Back To Top]](#top)


