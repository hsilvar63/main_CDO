# SCSS Testing with Flosum - Complete Guide

## Quick Start

### Prerequisites
- VS Code with Salesforce extensions installed
- Node.js and npm installed
- Flosum extension/integration configured in VS Code
- Git repository connected to Flosum

---

## Setup Steps

### 1. Install Dependencies

```bash
# In your project root
npm install
```

This installs the Sass compiler needed to convert SCSS to CSS.

---

### 2. Project Structure

Place your test component files in:
```
force-app/main/default/lwc/testScssComponent/
├── testScssComponent.js
├── testScssComponent.html
├── testScssComponent.js-meta.xml
├── testScssComponent.scss          ← Source file (not deployed)
└── testScssComponent.css           ← Generated file (deployed)
```

---

## Testing Workflows

### Option A: Manual Compilation (Recommended for Flosum)

**Step 1: Write your SCSS**
Edit `testScssComponent.scss` with your styles.

**Step 2: Compile to CSS**
```bash
npm run scss:build:single
```

This generates `testScssComponent.css` from your SCSS file.

**Step 3: Verify CSS was created**
Check that `testScssComponent.css` exists in the same directory.

**Step 4: Push to Flosum**
- Open VS Code
- Right-click on the `testScssComponent` folder
- Select your Flosum push/commit option
- **Important:** Ensure only `.css` file is included (SCSS should be ignored via .forceignore)

---

### Option B: Watch Mode (For Active Development)

**Terminal 1: Run watch mode**
```bash
npm run scss:watch
```

This automatically compiles SCSS → CSS whenever you save the SCSS file.

**Terminal 2: Work normally**
- Edit `testScssComponent.scss`
- Save the file
- CSS auto-generates
- Push to Flosum when ready

---

### Option C: Pre-Commit Hook (Advanced)

Automatically compile before every commit:

```bash
# .git/hooks/pre-commit
#!/bin/sh
npm run scss:build
git add force-app/main/default/lwc/**/*.css
```

Make it executable:
```bash
chmod +x .git/hooks/pre-commit
```

---

## Flosum-Specific Workflow

### Method 1: Direct Push from VS Code

1. **Compile SCSS**
   ```bash
   npm run flosum:push
   ```

2. **Push via Flosum Extension**
   - Open Source Control panel in VS Code
   - Stage your changes (should include `.css`, not `.scss`)
   - Commit with message
   - Push to Flosum repository

3. **Verify in Flosum**
   - Log into Flosum
   - Check that CSS file appears in the changeset
   - Verify SCSS file is NOT included

### Method 2: Git Commit → Flosum Sync

1. **Compile and commit locally**
   ```bash
   npm run scss:build
   git add force-app/main/default/lwc/testScssComponent/
   git commit -m "feat: add test SCSS component"
   git push
   ```

2. **Flosum auto-syncs** (if configured)
   - Changes appear in Flosum
   - Create deployment package
   - Deploy to target org

### Method 3: Flosum CLI (If available)

```bash
# Compile first
npm run scss:build

# Push to Flosum
flosum push --component lwc/testScssComponent
```

---

## Verification Checklist

### Before Pushing to Flosum

- [ ] SCSS file exists: `testScssComponent.scss`
- [ ] CSS file was generated: `testScssComponent.css`
- [ ] CSS file contains compiled styles (not SCSS syntax)
- [ ] `.forceignore` includes `**/*.scss`
- [ ] Git status shows `.css` changes (not `.scss`)

### After Pushing to Flosum

- [ ] Flosum repository shows `.css` file
- [ ] Flosum repository does NOT show `.scss` file
- [ ] Changeset includes the LWC bundle
- [ ] No deployment errors in Flosum

### After Deployment to Org

- [ ] Component appears in Setup → Lightning Components
- [ ] Add component to a Lightning page
- [ ] Verify styles are applied correctly
- [ ] Test button interactions
- [ ] Check responsive behavior

---

## Testing the Component

### 1. Deploy to Org

Via Flosum:
- Create deployment package
- Add testScssComponent to package
- Deploy to target org

### 2. Add to Lightning Page

1. Go to any App Builder page
2. Edit the page
3. Drag `testScssComponent` onto the page
4. Save and activate

### 3. Visual Verification

Check that these elements are styled correctly:
- Header should be blue (#0176d3)
- Cards should have borders and shadows
- Buttons should have different colors
- Hover effects should work
- Grid layout should be responsive

---

## Common Issues and Solutions

### Issue 1: "SCSS file deployed to org"

**Symptom:** SCSS file appears in Salesforce org
**Cause:** `.forceignore` not configured properly
**Solution:**
```bash
# Add to .forceignore
echo "**/*.scss" >> .forceignore
```

### Issue 2: "Component has no styles"

**Symptom:** Component appears unstyled in Salesforce
**Cause:** CSS file not generated or not deployed
**Solution:**
```bash
# Regenerate CSS
npm run scss:build:single

# Verify it exists
ls -la force-app/main/default/lwc/testScssComponent/

# Should see both .scss and .css
```

### Issue 3: "Flosum shows SCSS in changeset"

**Symptom:** SCSS file appears in Flosum pending changes
**Cause:** File was added before .forceignore was configured
**Solution:**
```bash
# Remove SCSS from tracking
git rm --cached force-app/main/default/lwc/**/*.scss

# Commit the removal
git commit -m "chore: remove SCSS from version control"
```

### Issue 4: "CSS not updating in org"

**Symptom:** Changes to SCSS don't appear after deployment
**Cause:** CSS wasn't recompiled before deployment
**Solution:**
```bash
# Always compile before pushing
npm run scss:build
```

### Issue 5: "Team members can't compile SCSS"

**Symptom:** Other developers don't have Sass installed
**Solution:**
Document in README:
```bash
# First-time setup
npm install

# Before any Flosum push
npm run scss:build
```

---

## Best Practices for Flosum + SCSS

### 1. Always Compile Before Committing
```bash
npm run scss:build && git add . && git commit -m "your message"
```

### 2. Include Both Files in Repo
- Keep `.scss` for source control and maintenance
- Include `.css` for deployment
- Use `.forceignore` to exclude SCSS from Salesforce

### 3. Document for Team
Create a CONTRIBUTING.md:
```markdown
## Working with SCSS

1. Edit `.scss` files only
2. Run `npm run scss:build` before committing
3. Verify `.css` file updated
4. Push to Flosum
```

### 4. Add to CI/CD (If applicable)
```yaml
# Flosum pipeline example
steps:
  - name: Install dependencies
    run: npm install
  
  - name: Compile SCSS
    run: npm run scss:build
  
  - name: Deploy to Flosum
    run: flosum deploy
```

### 5. Code Review Checklist
- [ ] SCSS changes are logical and maintainable
- [ ] CSS was regenerated from SCSS
- [ ] CSS matches SCSS output
- [ ] No manual CSS edits (always edit SCSS)

---

## Quick Reference Commands

```bash
# Install dependencies
npm install

# Compile single file
npm run scss:build:single

# Compile all SCSS files
npm run scss:build

# Watch mode (auto-compile on save)
npm run scss:watch

# Compile before Flosum push
npm run flosum:push

# Verify files
ls -la force-app/main/default/lwc/testScssComponent/
```

---

## File Checklist

**Required files in your component:**
- ✅ `testScssComponent.js` (controller)
- ✅ `testScssComponent.html` (template)
- ✅ `testScssComponent.css` (compiled styles - DEPLOY THIS)
- ✅ `testScssComponent.js-meta.xml` (metadata)

**Optional but recommended:**
- ✅ `testScssComponent.scss` (source styles - keep in repo, don't deploy)

**Configuration files:**
- ✅ `package.json` (build scripts)
- ✅ `.forceignore` (exclude SCSS from deployment)

---

## Troubleshooting Script

```bash
#!/bin/bash
# Run this if you're having issues

echo "Checking SCSS setup..."

# Check if Sass is installed
if command -v sass &> /dev/null; then
    echo "✅ Sass is installed"
else
    echo "❌ Sass not found. Run: npm install"
fi

# Check if SCSS file exists
if [ -f "force-app/main/default/lwc/testScssComponent/testScssComponent.scss" ]; then
    echo "✅ SCSS file exists"
else
    echo "❌ SCSS file not found"
fi

# Check if CSS file exists
if [ -f "force-app/main/default/lwc/testScssComponent/testScssComponent.css" ]; then
    echo "✅ CSS file exists"
else
    echo "❌ CSS file not found. Run: npm run scss:build:single"
fi

# Check .forceignore
if grep -q "**/*.scss" .forceignore; then
    echo "✅ .forceignore configured correctly"
else
    echo "⚠️  .forceignore might not exclude SCSS files"
fi

echo "Done!"
```

---

## Expected Results

After successful deployment:
1. Component appears in Salesforce Setup
2. Styles render correctly on Lightning pages
3. Colors match SCSS variables
4. Hover effects work on buttons
5. Grid layout is responsive
6. No console errors

---

## Next Steps

1. ✅ Set up your project with these files
2. ✅ Run `npm install`
3. ✅ Compile SCSS: `npm run scss:build:single`
4. ✅ Verify CSS file was created
5. ✅ Push to Flosum via VS Code
6. ✅ Deploy from Flosum to your org
7. ✅ Test the component on a Lightning page

---

## Support Resources

- **Sass Documentation:** https://sass-lang.com/documentation
- **LWC Dev Guide:** https://developer.salesforce.com/docs/component-library/documentation/en/lwc
- **Flosum Documentation:** [Your Flosum instance docs]

---

*Last Updated: 2026-02-05*
